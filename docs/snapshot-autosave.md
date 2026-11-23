# Save a snapshot after each scan

In **Settings → Scanning**, turn on **Save a snapshot after each scan** and
choose a destination folder. The setting is off by default.

When you finish scanning a folder or volume, Radix saves a timestamped
`.radixscan` file in your chosen destination. Rescan the entire target to
save another snapshot, then compare the two in Radix to see where disk
usage changed.

You still start each scan yourself. Automatic folder refreshes,
rescans of individual folders within a result, and cancelled or failed scans
skip autosave.
