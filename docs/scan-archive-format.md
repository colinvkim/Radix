# Scan Archive Format

Radix scan archives are `.radixscan` package directories. Import is read-only: loaded snapshots use `ScanSnapshotSource.imported`, keep path-copy/open support when path mode allows it, and never enable file mutation actions.

## Common Package Layout

- `manifest.json`: format header, snapshot summary, section names, node checksum.
- `nodes.jsonl`: one node record per line. Checksum covers exact bytes, including line breaks.
- `topology.json`: root ID and child edges. Parent edges are rebuilt and validated during import.
- `warnings.json`: archived scan warnings.
- `stats.json`: archived aggregate stats. Import recomputes stats from nodes and records a warning if repaired.

## Version 1

Version 1 uses verbose JSON node keys such as `id`, `path`, `allocatedSize`, and `isDirectory`. Topology archives may include `parentIDByID`; import validates it when present. Radix still reads v1 archives.

## Version 2

Version 2 keeps the same package layout but writes compact node records:

- Short JSON keys reduce `nodes.jsonl` size.
- Default values are omitted, including false booleans, `linkCount == 1`, `logicalSize == allocatedSize`, and `unduplicatedAllocatedSize == allocatedSize`.
- `path` is omitted when it matches `id`; synthetic nodes keep an explicit path.
- `lastModified` is stored as seconds since 1970.
- Export omits `parentIDByID`; import rebuilds it from child edges.
- Section JSON is compact, not pretty-printed.

Import accepts versions `1...ScanArchiveService.currentFormatVersion` and rejects future versions before decoding version-specific bodies.
