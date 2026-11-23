# Proposal: Save a snapshot after each scan

In **Settings → Scanning**, turn on **Save a snapshot after each scan** and
choose a destination folder. The setting would be off by default.

Whenever you finish scanning a folder or volume, Radix would save a new,
timestamped `.radixscan` file in that folder. Rescanning the entire target
would create another snapshot. You could then compare the two in Radix to
see where disk usage changed.

You would still start each scan yourself. Automatic folder refreshes,
rescans of individual folders within a result, and cancelled or failed scans
would skip autosave.
