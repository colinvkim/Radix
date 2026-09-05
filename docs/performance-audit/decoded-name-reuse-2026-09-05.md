**Decoded filename reuse experiment — 5 September 2026**

Do not retain this prototype. Reusing the native enumerator's decoded filename did not show a convincing complete-scan benefit across the measured workloads. The experiment was removed; production code remains identical to `fa4308a`, including the previously accepted path-reuse optimization.

The candidate added an optional `decodedName` to `DirectoryEntry`, populated only for native files and symlinks with metadata. Both worker and coordinator leaf preparation passed it to `makeFileNode`, avoiding another `URL.lastPathComponent` extraction. Directories, roots, failures, and Foundation entries retained their existing naming behavior. This required an extra field on every directory entry, even when nil; native leaf strings also lived longer. The [saved prototype patch](/Users/colin/Programming/Radix/docs/performance-audit/decoded-name-reuse-prototype-2026-09-05.patch) includes the complete production change and focused test extensions. It is not applied.

| Complete scan, median of six pairs | Baseline | Prototype | Time change | Median peak RSS change |
| --- | ---: | ---: | ---: | ---: |
| 200,000 files, wide ASCII directory | 2.215 s | 2.306 s | +4.1% | +1.17 MB |
| 200,000 files, long Unicode paths | 6.607 s | 6.651 s | +0.7% | +1.31 MB |
| 2,000 directories × 100 ASCII files | 0.634 s | 0.645 s | +1.7% | +0.63 MB |
| `/Applications`, packages collapsed | 1.440 s | 1.493 s | +3.7% | −0.11 MB |

Positive time changes mean slower observed medians. These differences do not establish universal regressions: all before/after ranges overlap, and order effects are large. ASCII baseline medians were 3.088 s when run first and 1.339 s when run second; prototype medians were 3.008 s and 1.392 s. The much faster second scan follows whichever version runs first. An initial warm-up per workload did not eliminate this effect across the interleaved workload sequence. It is consistent with filesystem caching, but cache state was not directly measured.

Separating results by run position also gives mixed evidence. Unicode medians improved modestly in both positions (6.959→6.869 s first, 6.339→6.154 s second), while ASCII and branching results changed direction between positions. There are only three samples per version/position. This narrow indication on deliberately long Unicode paths is insufficient to justify retaining the extra field and strings for all scans. The decision is based on the absence of a convincing overall benefit, not a claim that extracting names again is free.

All 56 completed scans, including eight warm-ups, matched per-workload file/directory/node counts, logical and allocated byte totals, zero warnings, and tree fingerprints. The package workload also matched semantic fingerprints. Every generated fixture contained 200,000 empty files; the wide fixtures retained 200,001 nodes and the branching fixture retained 202,001 nodes. These checks exclude correctness drift as an explanation for the timings.

**Method and reproduction**

Baseline: `fa4308aae921de3953a8a2c5fe737190bd83d87d`. Both bundles used the existing benchmark code, with no timing-hook changes. Hardware and environment: Apple M5, ten cores, 32 GiB RAM, macOS 26.6.2, Xcode 26.6 (17F113), local APFS, Release configuration, outside the command sandbox. Builds and fixture creation did not overlap timed runs. Caches and background load were uncontrolled. No cold-cache guarantee, cloud/network-volume measurement, or live UI latency measurement is implied.

Each process ran one XCTest benchmark. Workload order was ASCII, Unicode, branching, then applications. One warm-up pair per workload was excluded, followed by six measured pairs: baseline first in odd rounds, prototype first in even rounds. The sixth pair was added after observing a strong order effect in the initial five, giving each version three first and three second positions. No completed sample was discarded as an outlier.

The wide fixture shapes match the [path-reuse experiment](/Users/colin/Programming/Radix/docs/performance-audit/path-reuse-2026-09-05.md): ASCII names `file-{index:08}.dat`; Unicode names `文件-cafe\u0301-{index:08}-100% #?.dat` under 24 nested `层级-é-😀-路径-{index:02}` components, scanning the deepest directory directly. The branching fixture uses 2,000 `dir-{index:04}` directories with 100 empty `file-{index:08}.dat` files each. The combining-accent escape denotes a literal Unicode character. Absolute fixture paths are retained in the results because tree fingerprints depend on them.

For reproduction, build baseline and prototype Release test bundles in separate copies, applying the saved patch only to the prototype. Invoke Xcode's `xctest -XCTest` through `rtk proxy`, keeping each bundle's basename `RadixCorePackageTests.xctest`. Generated fixtures use `RadixCoreTests.PerformanceAuditBenchmarkTests/testFilesystemAuditBenchmark` with `RADIX_BENCH_AUDIT_PATH` set to each scan root. Use the default native scanner policy, with no traversal-worker or compatibility override. The package workload uses `RadixCoreTests.FullDiskScanScalingBenchmarkTests/testFullDiskScanScalingBenchmark`, `RADIX_BENCH_FULL_SCAN_SCALING=1`, `RADIX_BENCH_FULL_SCAN_PATH=/Applications`, `RADIX_BENCH_FULL_SCAN_SCENARIO=collapsed-auto-none`, and `RADIX_BENCH_FULL_SCAN_CANCELLATION=0`.

[Raw results](/Users/colin/Programming/Radix/docs/performance-audit/decoded-name-reuse-results-2026-09-05.json) preserve every process, medians, ranges, and medians by run position. Both test bundles, process logs, fixture generator, and benchmark runners remain under `.build/name-reuse-audit`.

The generated filesystem fixtures were removed after measurement; scanned application files were not changed. After removing the prototype and its test extensions, the restored code passed the complete core suite (932 tests, 35 skipped, zero failures) and the full Debug app build at `.build/xcode-derived-data`.

The prototype passed 165 focused Release scanner/model/descriptor tests, with two filesystem-dependent skips and zero failures. Coverage included byte-for-byte native/Foundation naming parity for combining accents and literal percent/punctuation names, worker/coordinator parity, descriptor traversal, fallback, and cancellation. The skipped tests require invalid UTF-8 filenames or canonically equivalent names that the local APFS filesystem rejects or folds. No enumeration, fallback, or cancellation scheduling code was changed.

Keep decoded-name reuse closed unless a new profile or different design provides stronger evidence. Overlapping wide-directory enumeration and leaf preparation remains a separate, larger opportunity that this experiment did not implement or benchmark.
