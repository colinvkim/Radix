import Foundation

/// Applies scan namespace and user-exclusion policy to enumerated directory entries.
///
/// Both the bulk and Foundation enumeration paths use this policy so fallback cannot
/// silently change which filesystem entries a scan includes.
nonisolated enum ScanDirectoryEntryFilter {
    static func filteredEntries(
        _ entries: [DirectoryEntry],
        under parentURL: URL,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck
    ) throws -> [DirectoryEntry] {
        var filteredEntries: [DirectoryEntry] = []
        filteredEntries.reserveCapacity(entries.count)
        let parentPath = parentURL.path

        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            let isDirectory = entry.metadata?.isDirectory ?? entry.isDirectoryHint ?? entry.url.hasDirectoryPath
            let childPath = entry.url.path
            guard includes(
                childName: entry.url.lastPathComponent,
                parentPath: parentPath,
                behavior: behavior
            ),
                  !exclusionMatcher.excludesKnownNormalizedPath(
                    childPath,
                    isDirectory: isDirectory
                  ) else {
                continue
            }
            filteredEntries.append(entry)
        }

        try cancellationCheck()
        return filteredEntries
    }

    static func entriesForLocalizedFailures(
        _ failures: [ScanEngine.DirectoryEnumerationFailure],
        under parentURL: URL,
        behavior: ScanEngine.ScanBehavior,
        exclusionMatcher: ScanExclusionMatcher
    ) -> [DirectoryEntry] {
        failures.compactMap { failure in
            let isDirectoryHint = failure.isDirectoryHint ?? failure.url.hasDirectoryPath
            guard includes(failure.url, under: parentURL, behavior: behavior),
                  !exclusionMatcher.excludesKnownNormalizedPath(
                      failure.url.path,
                      isDirectory: isDirectoryHint
                  ) else {
                return nil
            }
            return DirectoryEntry(
                url: failure.url,
                metadata: nil,
                localizedEnumerationError: failure.error,
                isDirectoryHint: isDirectoryHint
            )
        }
    }

    static func includes(
        _ childURL: URL,
        under parentURL: URL,
        behavior: ScanEngine.ScanBehavior
    ) -> Bool {
        includes(
            childName: childURL.lastPathComponent,
            parentPath: parentURL.path,
            behavior: behavior
        )
    }

    static func includes(
        childName: String,
        parentPath: String,
        behavior: ScanEngine.ScanBehavior
    ) -> Bool {
        if parentPath == "/" {
            switch childName {
            case ".nofollow", ".resolve":
                return false
            case ".file", ".vol", "dev", "Volumes":
                return !behavior.excludesStartupVolumeInternals
            default:
                return true
            }
        }

        return !behavior.excludesStartupVolumeInternals
            || parentPath != "/System"
            || childName != "Volumes"
    }
}
