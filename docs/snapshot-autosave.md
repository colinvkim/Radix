# Save a snapshot after each scan

In **Settings → Scanning**, turn on **Save a snapshot after each scan** and
choose a destination folder. The setting is off by default.

Autosave includes folders and volumes by default. Turn on **Only save
volume scans** to limit it to whole volumes. For example, scanning an
external volume then saves a snapshot. Scanning a folder on that volume
skips autosave.

Radix writes a timestamped `.radixscan` file in your chosen destination.
When **Snapshot Saved** appears, select **Show in Finder** to see the
archive. Rescan the entire target to save another snapshot, then compare
the two in Radix to see where disk usage changed.

You still start each scan yourself. Automatic folder refreshes,
rescans of individual folders within a result, and cancelled or failed scans
skip autosave.
