#!/usr/bin/env python3
"""Compare package/summary representation and warnings across worker counts."""

import argparse
import json
import os
from pathlib import Path
import subprocess


WORKERS = (5, 12, 16)
RESULT_PREFIX = "RADIX_BENCH_FULL_SCAN_SCALING_RESULT "


def verify(records):
    pairs = [(record["round"], record["workers"]) for record in records]
    rounds = sorted({pair[0] for pair in pairs})
    expected = {(round_index, workers) for round_index in rounds for workers in WORKERS}
    if len(rounds) < 2 or set(pairs) != expected or len(pairs) != len(expected):
        raise SystemExit("Need at least two complete rounds with one scan per worker count.")
    configurations = {
        (record["path"], record["scenario"], record.get("representationExcludedPath"))
        for record in records
    }
    if len(configurations) != 1:
        raise SystemExit("Cannot compare different paths, scenarios, or excluded paths.")
    signatures = {
        (record["representationFingerprint"], record["warningFingerprint"], record["warningEvents"])
        for record in records
    }
    if len(signatures) != 1:
        raise SystemExit("INCONCLUSIVE. Recorded representation or warnings changed between scans.")
    print(f"PASS. {len(rounds)} scans per worker count share package/summary and warning fingerprints.")
    print("Ordinary-node completeness is not measured by the representation fingerprint.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-records", type=Path)
    parser.add_argument("--checkout", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path)
    parser.add_argument("--path", default="/Applications")
    parser.add_argument("--allow-root", action="store_true")
    parser.add_argument("--rounds", type=int, default=2)
    args = parser.parse_args()
    if args.verify_records:
        verify(json.loads(args.verify_records.read_text()))
        return
    if args.rounds < 2:
        parser.error("--rounds must be at least 2")
    if args.output is None:
        parser.error("--output is required for a scan")
    scan_path = str(Path(args.path).resolve(strict=True))
    if scan_path == "/" and not args.allow_root:
        parser.error("scanning / requires --allow-root")
    checkout = args.checkout.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    records = []
    for round_index in range(1, args.rounds + 1):
        for workers in WORKERS:
            env = os.environ | {
                "RADIX_BENCH_FULL_SCAN_SCALING": "1",
                "RADIX_BENCH_FULL_SCAN_ALLOW_ROOT": "1" if args.allow_root else "0",
                "RADIX_BENCH_FULL_SCAN_PATH": scan_path,
                "RADIX_BENCH_FULL_SCAN_SCENARIO": "collapsed-auto-none",
                "RADIX_BENCH_FULL_SCAN_CANCELLATION": "0",
                "RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS": str(workers),
            }
            log = output / f"round-{round_index}-workers-{workers}.log"
            with log.open("w") as stream:
                result = subprocess.run(
                    ["swift", "test", "-c", "release", "--skip-build", "--filter",
                     "FullDiskScanScalingBenchmarkTests/testFullDiskScanScalingBenchmark"],
                    cwd=checkout, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=600,
                )
            if result.returncode:
                raise SystemExit(f"Worker run failed. See {log}")
            matches = [line.split(RESULT_PREFIX, 1)[1] for line in log.read_text().splitlines()
                       if RESULT_PREFIX in line]
            if len(matches) != 1:
                raise SystemExit(f"Expected one completed scan in {log}")
            record = json.loads(matches[0]) | {"round": round_index, "workers": workers}
            records.append(record)
            (output / "records.json").write_text(json.dumps(records, indent=2) + "\n")
            print(json.dumps({key: record[key] for key in (
                "round", "workers", "retainedNodes", "representationFingerprint",
                "warningFingerprint", "warningEvents",
            )}), flush=True)
    verify(records)


if __name__ == "__main__":
    main()
