import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile

parser = argparse.ArgumentParser(description='Compare complete scans of a rejected auto-summary probe fixture.')
parser.add_argument('baseline', type=Path)
parser.add_argument('candidate', type=Path)
parser.add_argument('--baseline-scratch', type=Path, required=True)
parser.add_argument('--candidate-scratch', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--rounds', type=int, default=5)
args = parser.parse_args()
if args.rounds < 5:
    parser.error('Use at least five alternating rounds.')
args.output.mkdir(parents=True, exist_ok=True)
records = []
reference = None

with tempfile.TemporaryDirectory(prefix='RadixRejectedProbe-') as temporary:
    fixture = Path(temporary).resolve()
    files = fixture / 'projects' / 'node_modules' / 'shard'
    files.mkdir(parents=True)
    payload = bytes(8192)
    for index in range(6000):
        (files / f'payload-{index}.bin').write_bytes(payload)
    sides = {
        'baseline': (args.baseline.resolve(), args.baseline_scratch.resolve()),
        'candidate': (args.candidate.resolve(), args.candidate_scratch.resolve()),
    }
    env = os.environ | {
        'RADIX_BENCH_FULL_SCAN_SCALING': '1',
        'RADIX_BENCH_FULL_SCAN_PATH': str(fixture),
        'RADIX_BENCH_FULL_SCAN_SCENARIO': 'collapsed-auto-none',
        'RADIX_BENCH_FULL_SCAN_CANCELLATION': '0',
        'RADIX_SCAN_DIRECTORY_TRAVERSAL_WORKERS': '5',
    }
    for round_index in range(args.rounds + 1):
        order = ['baseline', 'candidate'] if round_index % 2 == 0 else ['candidate', 'baseline']
        for side in order:
            checkout, scratch = sides[side]
            log = args.output / f'round-{round_index}-{side}.log'
            with log.open('w') as stream:
                completed = subprocess.run([
                    'swift', 'test', '-c', 'release', '--scratch-path', str(scratch),
                    '--skip-build', '--filter',
                    'FullDiskScanScalingBenchmarkTests/testFullDiskScanScalingBenchmark',
                ], cwd=checkout, env=env, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
            if completed.returncode:
                raise SystemExit(f'FAIL. See {log}')
            prefix = 'RADIX_BENCH_FULL_SCAN_SCALING_RESULT '
            matches = [line.split(prefix, 1)[1] for line in log.read_text().splitlines() if prefix in line]
            if len(matches) != 1:
                raise SystemExit(f'FAIL. Expected one completed scan in {log}')
            raw = json.loads(matches[0])
            expected = {'aggregateFiles': 6000, 'aggregateDirectories': 4,
                        'logicalBytes': 49_152_000, 'retainedNodes': 6004,
                        'packageNodes': 0, 'autoSummarizedNodes': 0, 'warningEvents': 0}
            for key, value in expected.items():
                if raw[key] != value:
                    raise SystemExit(f'FAIL. {key} is {raw[key]}, expected {value}. See {log}')
            fingerprints = (raw['treeFingerprint'], raw['semanticFingerprint'], raw['warningFingerprint'])
            if reference is None:
                reference = fingerprints
            if fingerprints != reference:
                raise SystemExit(f'FAIL. Snapshot fingerprints changed. See {log}')
            if round_index:
                keys = ['wallSeconds', 'userCPUSeconds', 'systemCPUSeconds', 'retainedNodes',
                        'aggregateFiles', 'aggregateDirectories', 'logicalBytes', 'allocatedBytes',
                        'warningEvents', 'treeFingerprint', 'semanticFingerprint', 'warningFingerprint']
                record = {key: raw[key] for key in keys} | {'round': round_index, 'side': side}
                records.append(record)
                (args.output / 'records.json').write_text(json.dumps(records, indent=2) + '\n')
                print(json.dumps(record), flush=True)
for side in ('baseline', 'candidate'):
    samples = [record['wallSeconds'] for record in records if record['side'] == side]
    print(f'{side} n={len(samples)} median_seconds={statistics.median(samples):.6f} min_seconds={min(samples):.6f} max_seconds={max(samples):.6f}', flush=True)
print('PASS. Both complete scans produced identical trees, totals, and warnings in every round.', flush=True)
