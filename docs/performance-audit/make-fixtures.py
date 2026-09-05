"""Create the audit's filesystem shapes in a fresh temporary directory."""

import json
from pathlib import Path
import tempfile


root = Path(tempfile.mkdtemp(prefix="radix-audit-", dir="/private/tmp"))
wide = root / "wide"
wide.mkdir()
for index in range(10_000):
    (wide / f"file-{index:08}.dat").write_bytes(b"A")

fanout = root / "fanout"
fanout.mkdir()
for directory_index in range(100):
    directory = fanout / f"dir-{directory_index:04}"
    directory.mkdir()
    for file_index in range(1_000):
        (directory / f"file-{file_index:08}.dat").write_bytes(b"A")

print(json.dumps({"root": str(root), "wide": str(wide), "fanout": str(fanout)}, indent=2))
