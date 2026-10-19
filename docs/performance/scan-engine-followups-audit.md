# Scan follow-up final evidence audit

PASS for the final production closeout evidence and draft status documents. No actionable claim-accuracy or evidence finding remains from these three audit checkpoints. The status-document PR was not yet published when this audit ran.

This is an independent evidence lens using the inherited parent model. It does not claim model diversity. The reviewer read saved receipts, the final draft files, local commit history, source spot checks, and parent-provided run context. The complete preceding parent tool transcript was unavailable. No tests, builds, scans, benchmarks, app interactions, source changes, git mutations, or subagents ran during this audit. The only written artifact is this report.

## Final receipts checked

The journal branch contains regression commit `610e692` and fix commit `a021019`. Its independent functional/comment review records PASS. `/tmp/radix-scan-work/journal-alias-full-tests.log:2521` records 1,115 tests in 74 suites passing. `/tmp/radix-scan-work/journal-alias-debug-build.log:1335` records `BUILD SUCCEEDED`. The review's originally pending parent gates are therefore completed by later receipts, rather than retroactively claimed by that review.

The combined integration checkout ends at `b981ab0`, including the journal fix after the four earlier production branches. `/tmp/radix-scan-work/integration-final-tests.log:2606` records 1,141 tests in 78 suites passing. `/tmp/radix-scan-work/integration-final-debug-build.log:214` records `BUILD SUCCEEDED` and identifies the integration checkout's exact Debug output bundle. The final documents correctly distinguish this result from the earlier 1,136-test integration tree without the journal fix.

The four `journal-alias-probe-{tmp,var,users,data}.log` receipts each contain three successful rename trials. Every trial's emitted events include both rename endpoints in the caller's namespace. The log headers identify physical subscriptions under `/System/Volumes/Data` and the correct relative targets. The saved helper source requires both paths with rename flags before declaring success. It does not accept HistoryDone alone as proof of a correct history. These receipts support twelve observed successful trials, rather than a universal delivery guarantee.

`manual-final-instance.log` records one Radix process, PID 12857, with executable path `/Users/colin/.codex/worktrees/scan-engine-followups/Radix/.build/xcode-derived-data/Build/Products/Debug/Radix.app/Contents/MacOS/Radix`. `manual-final.log` records the actual Computer Use observations on integration `b981ab0`. The initial UI showed 12 KB, two files, three folders, and zero warnings. After the changed file grew from 8,192 to 16,384 bytes, Rescan Entire Scan showed 20 KB, with Changed at 16 KB and Untouched at 4 KB. The next unchanged rescan kept 20 KB and reported no changes. This repeats the original failed operation on the final combined Debug bundle. The receipt is an owner-written summary of observed accessibility output, not an exported screenshot or a reviewer rerun. The draft accurately labels Computer Use and does not claim the optional forced partial-listing check ran.

The service regression source independently asserts 12,288 bytes before mutation, 20,480 afterward, and 16,384 for the changed payload. It compares the rescan with a fresh full tree. This supports the semantic result separately from the UI's rounded size presentation.

## Final document and trail checks

Read the final draft `docs/scan-engine-remaining.md` and `docs/performance/scan-engine-followups-validation.md` in `/Users/colin/.codex/worktrees/scan-exclusion-case/Radix`. Their test counts, proposed PR assignments, journal trial count, manual result, and controlled benchmark claims match the inspected receipts. They describe PRs 85 through 89 as proposed and unmerged. Publication and attachment of those PRs are supported by the parent-provided context and canonical delivery rows; this audit did not repeat external publication checks.

The candidate `docs/performance/scan-engine-followups-decisions.tsv` is identical to the canonical `/tmp/radix-scan-work/decisions.tsv` at this checkpoint. The previously missing relative trail link now resolves. The appended rows preserve the original inconclusive worker series, add its completed successor, record the journal scope extension and separate delivery, and record final combined and manual outcomes. No prior row was rewritten to conceal a failed or unfinished approach.

The selected worker records and rerunnable tool retain the narrow representation comparison established in the second audit. The drafts do not turn matching package/summary fingerprints into a proof about ordinary nodes. The approximately 70,000-node 12-worker difference remains visible in the table. The controlled 10.0% median scan improvement remains limited to the 6,000-file fixture. The overlapping micro timings remain inconclusive. Profiler timings remain excluded. Resource limits remain per-probe entry retention rather than global memory or I/O guarantees.

The draft now preserves the separate journal boundaries explicitly. Descriptor capture does not close the preexisting baseline-eligibility gap. Arbitrary symlink-retarget safety, writable external-disk live history, universal rename-pair delivery, and a production HistoryDone timeout are not claimed. Optional optimization and measurement work remain listed rather than silently presented as completed.

## Remaining delivery step

Publish the reviewed status documents, trail snapshot, selected worker records, and worker tool in the final documentation PR. Mark the already completed journal, integration, and manual checklist items complete. Append the final audit and publication outcomes to the canonical trail and keep the published snapshot current. Those are delivery bookkeeping steps after this evidence audit, not unresolved production verification failures.

## Attention for the operator

Reviewed by the inherited parent model with an independent evidence lens.

No actionable audit findings. The five production PRs are proposed changes. The 10.0% measurement applies only to the controlled fixture. Worker ordinary-node completeness, full-disk performance, external-disk live history, and a production HistoryDone timeout remain unverified or intentionally open, as the status document states.
