#!/usr/bin/env python3
import argparse
import re
import signal
import subprocess
import sys
from pathlib import Path

mutations = [
    ("byte-estimate", "Radix/Models/ScanProgress.swift", "if estimatedTotalBytes > 0 {", "if false {", "testByteEstimatePreventsPrematureFinalizingProgress", 0),
    ("chart-generation", "Radix/Services/ChartLayoutRequestCoordinator.swift", "generation == request.generation && activeLayoutID == request.layoutID", "activeLayoutID == request.layoutID", "testSupersededRequestCannotWinWhenLayoutIDIsReused", 0),
    ("chart-deinit", "Radix/Services/ChartLayoutRequestCoordinator.swift", "deinit {\n        activeTask?.cancel()\n    }", "deinit {}", "testDeinitializationCancelsRunningRequest", 0),
    ("presentation-reset", "Radix/ViewModels/AppPresentationCoordinator.swift", "queue.removeAll(keepingCapacity: false)", "_ = queue.count", "testResetClearsActiveAndQueuedPresentationsAndArchiveImports", 0),
    ("incomplete-baseline", "Radix/Services/IncrementalScanService.swift", "guard baseline.isComplete else {", "guard true else {", "testIneligibleBaseline", 0),
    ("imported-baseline", "Radix/Services/IncrementalScanService.swift", "guard baseline.source.allowsFileMutation else {", "guard true else {", "testIneligibleBaseline", 0),
    ("probe-fallback-threshold", "Radix/Services/AtomicDirectorySummaryProbe.swift", "profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount)", "profile.observedDirectoryCount > Self.directoryOnlyProbeLimit(minFileCount: minFileCount)", "testDirectoryOnlyProbe", 0),
    ("probe-bulk-threshold", "Radix/Services/AtomicDirectorySummaryProbe.swift", "profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount)", "profile.observedDirectoryCount > Self.directoryOnlyProbeLimit(minFileCount: minFileCount)", "testDirectoryOnlyProbe", 1),
    ("firmlink-comments", "Radix/Models/TrashSafetyPolicy.swift", 'guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else { return nil }', 'guard !trimmedLine.isEmpty else { return nil }', "testFirmlinkParserHandlesCommentsWhitespaceAndDefaultDataPaths", 0),
    ("firmlink-fallback", "Radix/Models/TrashSafetyPolicy.swift", "return entries.isEmpty ? fallbackFirmlinkEntries : entries", "return entries", "testUnreadableOrEmptyFirmlinkFilesRetainFallbackProtection", 0),
    ("tour-marker", "Radix/Services/TourPracticeDirectory.swift", "ownership.sessionID == id else { return nil }", "true else { return nil }", "testAbandonedCleanupRetainsUntrustedMarkers", 0),
    ("tour-live-process", "Radix/Services/TourPracticeDirectory.swift", "guard kill(ownership.processID, 0) == -1, errno == ESRCH else { continue }", "guard true else { continue }", "testAbandonedCleanupRemovesOnlyOwnedDirectoriesOfExitedProcesses", 0),
    ("tour-late-cleanup", "Radix/ViewModels/WorkspaceTourSessionController.swift", "Task.detached(priority: .utility) { directory.remove() }", "_ = directory", "testFinishingBeforePreparationRunsRemovesLateDirectoryWithoutPublishingTarget", 0),
    ("date-style", "Radix/Services/FileSizeFormatter.swift", "dateFormatter.dateStyle = .medium", "dateFormatter.dateStyle = .long", "testDateUsesLocalizedMediumDateAndShortTime", 0),
    ("manual-refresh-acknowledgement", "Radix/ViewModels/AppModel.swift", "self?.folderRefreshController?.refreshFinished(nodeID: nodeID, result: result)", "_ = result", "manualRescanAcknowledgesEarlierChangesAndPreservesLaterEvents", 0),
]
parser = argparse.ArgumentParser(description="Verify selected audit tests reject deliberate production mistakes. Run with no concurrent source writers or test jobs.")
parser.add_argument("--only", action="append", choices=[entry[0] for entry in mutations])
parser.add_argument("--output", type=Path, default=Path("/tmp/radix-test-audit-mutations"))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
args.output.mkdir(parents=True, exist_ok=True)
failures = []
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))

baseline = args.output / "baseline.log"
print("RUN unmutated baseline", flush=True)
with baseline.open("w") as stream:
    result = subprocess.run(["swift", "test"], cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=240)
if result.returncode != 0 or re.search(r"Test run with [1-9][0-9]* tests .* passed", baseline.read_text()) is None:
    raise SystemExit(f"Unmutated baseline did not pass: {baseline}")

for name, relative, before, after, selector, occurrence in mutations:
    if args.only and name not in args.only:
        continue
    path = root / relative
    original = path.read_bytes()
    source = original.decode()
    matches = list(re.finditer(re.escape(before), source))
    if len(matches) <= occurrence:
        raise SystemExit(f"Mutation {name} no longer matches {relative}; update its operator.")
    match = matches[occurrence]
    log = args.output / f"{name}.log"
    print(f"RUN {name}", flush=True)
    try:
        path.write_text(source[:match.start()] + after + source[match.end():])
        with log.open("w") as stream:
            result = subprocess.run(["swift", "test", "--filter", selector], cwd=root, stdout=stream, stderr=subprocess.STDOUT, timeout=240)
        output = log.read_text()
        issue = re.search(rf"Test [^\n]*(?:{selector})[^\n]*recorded an issue", output)
        failed = re.search(rf"Test [^\n]*(?:{selector})[^\n]*failed", output)
        caught = result.returncode != 0 and issue is not None and failed is not None
        if caught:
            print(f"CAUGHT {name} {log}", flush=True)
        else:
            failures.append(name)
            print(f"NOT VERIFIED {name} exit={result.returncode} {log}", flush=True)
    finally:
        path.write_bytes(original)
        if path.read_bytes() != original:
            raise SystemExit(f"Failed to restore {relative}")

if failures:
    raise SystemExit("Controls not verified: " + ", ".join(failures))
print("All selected mutations were caught; production sources restored.", flush=True)
