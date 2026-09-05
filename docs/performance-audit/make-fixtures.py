"""Create the audit's filesystem shapes in a fresh temporary directory."""

import argparse
import json
from pathlib import Path
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--wide-files", type=int, default=10_000)
parser.add_argument("--fanout-directories", type=int, default=100)
parser.add_argument("--files-per-directory", type=int, default=1_000)
parser.add_argument("--empty", action="store_true", help="Create empty files to isolate metadata storage.")
args = parser.parse_args()
if min(args.wide_files, args.fanout_directories, args.files_per_directory) < 1:
    parser.error("Fixture counts must be positive.")
payload = b"" if args.empty else b"A"

root = Path(tempfile.mkdtemp(prefix="radix-audit-", dir="/private/tmp"))
wide = root / "wide"
wide.mkdir()
for index in range(args.wide_files):
    (wide / f"file-{index:08}.dat").write_bytes(payload)

fanout = root / "fanout"
fanout.mkdir()
for directory_index in range(args.fanout_directories):
    directory = fanout / f"dir-{directory_index:04}"
    directory.mkdir()
    for file_index in range(args.files_per_directory):
        (directory / f"file-{file_index:08}.dat").write_bytes(payload)

print(json.dumps({"root": str(root), "wide": str(wide), "fanout": str(fanout)}, indent=2))
