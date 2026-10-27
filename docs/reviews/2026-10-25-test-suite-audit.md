# Radix Core test-suite audit, 2026-10-25

Implemented on `test/test-suite-audit`, starting from commit `bf6a2e0`.
The corrected audit's fourteen work items are completed or closed with the
evidence below.

Swift Testing now discovers 1,165 test functions in 93 Swift files, compared
with 1,135 functions in 89 files at the baseline. Parameterized cases are not
counted separately. The final core run passed across 83 suites. Its 39 gated
measurement and probe tests remained disabled in that run.

## Completed checklist

- [x] **1. Establish the baseline.** The unchanged full suite passed at `bf6a2e0`.
  The sandboxed attempt stalled in LaunchServices. The same suite passed with
  normal macOS service access. No tests were disabled to obtain the baseline.
- [x] **2. Cover firmlink parsing and loading.** Added parser tables and real-file
  protection checks for visible and Data-volume aliases, comments, whitespace,
  default paths, missing or empty files, invalid UTF-8, and directory input.
  The default production initializer uses the same private load/fallback path.
- [x] **3. Cover tour safety and cleanup.** Added private filesystem namespaces,
  ownership/permission checks, marker and process identity cases, active-process
  retention, abandoned removal, symlink rejection, and sentinel survival.
  Session tests cover normal finish, failed preparation, and finish before
  preparation runs. A directory-change signal proves late creation actually
  occurred and its directory was removed without publishing a target or error.
- [x] **4. Cover chart lifecycle.** Added successful completion, same-ID request
  supersession after success/error/cancellation, failure recovery, cancellation
  propagation, and cancellation during coordinator destruction.
- [x] **5. Cover incremental eligibility.** Added incomplete and imported baseline
  cases, changed path and kind, changed root identity, and unavailable identity.
  Tests assert the exact fallback reason and no incremental-history request.
- [x] **6. Cover atomic probing.** Added both enumeration paths at minimum, scaled,
  and capped directory-only thresholds, a below-threshold control, and real
  FileManager fallback using the existing bulk-failure mechanism.
- [x] **7. Strengthen assertions.** Fixed the byte-estimate fixture, protected
  host-dependent worker-budget relationships, attributed archive failures to
  their intended guards, and covered idle `.startNow` plus presentation reset.
- [x] **8. Make display expectations portable.** Replaced English-only formatter
  expectations with independent Foundation compatibility expectations. Added
  date/nil-date, synthetic display-name, and icon-precedence cases. The actual
  French Debug app also displayed localized capacities, sizes, names, and dates.
- [x] **9. Replace unnecessary waiting.** Passed one paired scheduling-clock
  dependency through AppModel into the existing refresh timing boundary.
  The manual-rescan integration test now advances simulated time instead of
  settling for six real seconds. The continuous-writes test stops after its
  first accepted refresh while retaining the maximum-delay exercise.
- [x] **10. Resolve uncertain findings.** Added matcher normalization, tree
  composition, recent-target decode, and reachable usage-stat encode-failure
  cases. Closed the unsupported recommendations listed below.
- [x] **11. Apply both removal candidates.** Preserved first-claim and
  identity-count assertions in the accumulator matrix before removing its
  overlapping test. Removed the duplicate snapshot-rejection test while keeping
  missing/root guard assertions and successful single-node removal coverage.
- [x] **12. Consolidate matching setup.** Parameterized deferred-start cancellation
  triggers, resident cloud layouts, and compressed archive sections. Shared
  recent-target persistence fakes and matching benchmark timing/result helpers.
  Kept distinct triggers, layouts, archive sizes and error cases, fake recording
  assertions, and missing/nil chart-selection checks.
- [x] **13. Clarify measurement guarantees.** Added a root-directory traversal
  invariant and moved invocation/interpretation prose into the performance
  guide. Kept different chart instrumentation and full-disk cancellation
  contracts separate. Validated traversal and compared both scan adapters on a
  tiny fixed fixture. Counts, sizes, modification times, and topology matched;
  file-identity representations and their complete fingerprints differed.
  No performance comparison or speedup is claimed.
- [x] **14. Verify and reconcile.** The full core suite and complete Debug app
  build passed. Fifteen deliberate production mistakes were caught by their
  intended tests, with production sources restored afterward. Independent
  preservation review found no lost contracts.

## Production changes

[TourPracticeDirectory](../../Radix/Services/TourPracticeDirectory.swift) retains
its configured root. Production supplies the existing app temporary namespace;
tests supply private roots. The existing path, UUID, UID, symlink, marker-size,
session, PID, and process-liveness guards remain.

[TrashSafetyPolicy](../../Radix/Models/TrashSafetyPolicy.swift) accepts a firmlink
file at its real construction boundary. The loader remains private. Production
still caches entries from the system file and preserves the existing fallback.

[AppDependencies](../../Radix/Services/AppDependencies.swift) carries a paired
refresh clock into the existing controller inputs. The production default
continues to use continuous time. No timing thresholds or user interactions
were changed.

## Main test owners

| Contract | Primary proof |
|---|---|
| Firmlink parsing and fallback protection | [TrashSafetyPolicyTests](../../RadixCoreTests/TrashSafetyPolicyTests.swift) |
| Tour directory safety | [TourPracticeDirectoryTests](../../RadixCoreTests/TourPracticeDirectoryTests.swift) |
| Session finish and late cleanup | [WorkspaceTourSessionControllerTests](../../RadixCoreTests/WorkspaceTourSessionControllerTests.swift) |
| Chart request outcomes and cancellation | [ChartLayoutRequestCoordinatorTests](../../RadixCoreTests/ChartLayoutRequestCoordinatorTests.swift) |
| Incremental rejection and worker budgets | [IncrementalScanServiceTests](../../RadixCoreTests/IncrementalScanServiceTests.swift) |
| Probe thresholds and fallback | [AtomicProbeReplayTests](../../RadixCoreTests/AtomicProbeReplayTests.swift) |
| Refresh integration and simulated time | [AppModelFolderRefreshTests](../../RadixCoreTests/AppModelFolderRefreshTests.swift) |
| Archive corruption and manifest attribution | [ScanArchiveServiceTests](../../RadixCoreTests/ScanArchiveServiceTests.swift) |
| Composition and ID collisions | [FileTreeStoreTests](../../RadixCoreTests/FileTreeStoreTests.swift) |
| Normalization and matching | [ScanExclusionMatcherTests](../../RadixCoreTests/ScanExclusionMatcherTests.swift) |

## Findings closed without additional changes

- Optimistic trash hiding, restoration, visibility publication, FinderInfo
  classification, and allocation-floor integration already have meaningful
  assertions. No duplicate tests were added for those original false gaps.
- `testAutoSummaryProbeStopsAtVolumeBoundary` has an eligible small file behind
  the rejected boundary. Its nil-summary assertion protects meaningful behavior.
  The audit did not justify stronger internal instrumentation.
- The logical-scope comparison checks a real representation-equivalence contract.
  A changed-third-snapshot extension remains optional, not required remediation.
- Recent-target encoding stores strings and a string-backed enum. No ordinary
  representable input requires an encoder-failure hook. Usage statistics do have
  Double fields; new nonfinite-value cases exercise the real failure path and
  preserve its current behavior of clearing the previously stored value.
- The unnamed batch K, Q, and N recommendations cannot be reconstructed.
  They are closed as unsupported, not treated as pending implementation.
- The 93 original test functions without the `test` prefix were discoverable.
  No rename campaign was justified.
- Trash and Quick Look fixture sharing was not needed to preserve or restore a
  contract. Their distinct entry points and assertions remain explicit.
- The selected-segment test's missing and nil cases remain. Volume-boundary tests
  were not merged into the unrelated exclusion matcher.
- Domain-specific fingerprints and the full-disk cancellation record remain
  separate. Similar names did not establish a shared contract.

## Verification

Run from the repository root:

```sh
swift test
xcodebuild -project Radix.xcodeproj -scheme Radix \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-derived-data build
python3 tools/verify-test-audit-mutations.py
```

The mutation tool first requires an unmutated green full-suite baseline.
It then introduces one selected mistake, requires an issue and failure from the
intended test, and restores the exact source bytes. Run it without concurrent
source writers or builds. Its controls cover byte estimates, chart generation
and destruction, presentation reset, baseline eligibility, both probe thresholds,
firmlink comments/fallback, marker identity, active-process retention, late tour
cleanup, date style, and refresh acknowledgement.

Final evidence for this run is under `/tmp/radix-audit-run/`:

- `baseline-unsandboxed.log` records the 1,135-test baseline.
- `final-tests.log` records the final 1,165-test run.
- `mutation-summary.log` records the first fourteen caught controls.
- `late-tour-summary.log` records the additional caught late-cleanup control.
- `app-build.log` records `BUILD SUCCEEDED`.
- `tour-cancellation-tests.log` records the direct cleanup-observation test.
- `traversal-validation.log`, `native-scan-validation.log`, and
  `foundation-scan-validation.log` record the controlled measurement-tool checks.
- `scan-adapter-comparison.json` records the per-node comparison that explains the
  unequal fingerprints. Temporary diagnostic output was removed afterward.
- `debug-smoke-check.json` records the exact Debug process, locale arguments,
  visible tour output, restored workspace, and removed practice-container path.
- `decisions.tsv` records decisions and corrections.

The Debug smoke test used exactly one instance of this checkout's bundle at
`.build/xcode-derived-data/Build/Products/Debug/Radix.app`, launched with French
language/locale arguments. The tour scanned four practice files, displayed French
dates and byte units, restored the empty workspace when stopped, and removed
its practice container. The temporary French session was then closed.

See [measurement-tool instructions](../performance/test-audit-benchmarks.md) for
fixture requirements and the distinction between reported checksums and assertions.

## Proof limits

Foreign-UID rejection remains source-reviewed. Ordinary tests cannot create a
directory genuinely owned by another UID without privilege. Current ownership
acceptance and the other real filesystem rejection paths are exercised.

The French live check is representative non-English validation, not a run under
every supported locale. Core formatter tests compare against independent SDK
formatters under the current locale; localization catalogs retain their existing
suite coverage.

No full-disk or million-entry performance run was performed. The tiny fixture
validates output and the stated adapter fields, not performance or identical
identity representations.
