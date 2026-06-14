//
//  AtomicDirectorySummaryWalker.swift
//  Radix
//
//  Created by Codex on 6/12/26.
//

import Foundation

extension AtomicDirectorySummarizer {
    nonisolated func summarizeSerial(
        at url: URL,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        #if DEBUG
        let summaryStart = diagnostics?.start()
        #endif
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        var visitedItems = 0
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.summary.enumerate",
                url: url,
                startedAt: summaryStart,
                itemCount: visitedItems,
                detail: "files=\(state.descendantFileCount)"
            )
        }
        #endif

        do {
            try cancellationCheck()
            let rootValues = try url.resourceValues(forKeys: ScanMetadataLoader.atomicSummaryResourceKeySet)
            updateAtomicAccessibility(rootValues.isReadable ?? false, in: state)
        } catch {
            recordAtomicWarning(for: url, error: error, in: state)
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicSummaryResourceKeys,
            options: enumeratorOptions,
            errorHandler: { childURL, error in
                state.isAccessible = false
                state.warnings.append(ScanWarningFactory.makeWarning(for: childURL, error: error))
                return true
            }
        ) else {
            return nil
        }

        while let nextObject = enumerator.nextObject() {
            guard let childURL = nextObject as? URL else { continue }
            try cancellationCheck()
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childURL,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            if exclusionMatcher.excludes(childURL, isDirectory: hintedIsDirectory) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let childMetadata = try metadataLoader.atomicSummaryMetadata(for: childURL)
                if exclusionMatcher.excludes(childURL, isDirectory: childMetadata.isDirectory) {
                    if childMetadata.isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                try await accumulateEnumeratedAtomicSummary(
                    for: childURL,
                    metadata: childMetadata,
                    into: state,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: treatPackagesAsDirectories,
                    workerLimit: workerLimit,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState,
                    skipDescendants: {
                        enumerator.skipDescendants()
                    }
                )
            } catch {
                recordAtomicWarning(for: childURL, error: error, in: state)
            }
        }

        return makeAtomicSummary(from: state)
    }

    /// Performs a fast recursive summary of a directory's size and file count.
    /// Reuses the directory's already-enumerated immediate children to avoid a second full
    /// pass over flat cache-like directories.
    nonisolated func summarizeReusingImmediateChildren(
        at url: URL,
        childEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool = true,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        ownerNodeID: String,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws -> AtomicDirectorySummary? {
        try cancellationCheck()
        #if DEBUG
        let summaryStart = diagnostics?.start()
        #endif
        let state = AtomicDirectorySummaryState(ownerNodeID: ownerNodeID)
        updateAtomicAccessibility(rootMetadata.isReadable, in: state)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.summary.reused_entries",
                url: url,
                startedAt: summaryStart,
                itemCount: childEntries.count,
                detail: "files=\(state.descendantFileCount)"
            )
        }
        #endif

        for (index, childEntry) in childEntries.enumerated() {
            try cancellationCheck()
            if index == 0 || index.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: childEntry.url,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }

            guard !exclusionMatcher.excludes(
                childEntry.url,
                isDirectory: childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
            ) else {
                continue
            }

            let childMetadata: NodeMetadata
            if let preloadedMetadata = childEntry.metadata {
                childMetadata = preloadedMetadata
            } else {
                do {
                    childMetadata = try metadataLoader.metadata(for: childEntry.url)
                } catch {
                    recordAtomicWarning(for: childEntry.url, error: error, in: state)
                    continue
                }
            }

            try await accumulateAtomicSummary(
                for: childEntry.url,
                metadata: childMetadata,
                into: state,
                includeHiddenFiles: includeHiddenFiles,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                workerLimit: workerLimit,
                exclusionMatcher: exclusionMatcher,
                cancellationCheck: cancellationCheck,
                metrics: &metrics,
                continuation: continuation,
                emissionState: &emissionState
            )
        }

        return makeAtomicSummary(from: state)
    }

    nonisolated private func accumulateAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else { return }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        if metadata.isDirectory {
            let nestedTreatsPackagesAsDirectories = metadata.isPackage ? true : treatPackagesAsDirectories
            if metadata.isPackage || !metadata.isSymbolicLink {
                if let nestedSummary = try await summarize(
                    at: url,
                    includeHiddenFiles: includeHiddenFiles,
                    treatPackagesAsDirectories: nestedTreatsPackagesAsDirectories,
                    workerLimit: workerLimit,
                    ownerNodeID: state.ownerNodeID,
                    exclusionMatcher: exclusionMatcher,
                    cancellationCheck: cancellationCheck,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                ) {
                    merge(nestedSummary, into: state)
                }
            }
            return
        }

        accumulateAtomicFile(metadata, url: url, into: state)
    }

    nonisolated private func merge(_ summary: AtomicDirectorySummary, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += summary.allocatedSize
        state.logicalSize += summary.logicalSize
        state.descendantFileCount += summary.descendantFileCount
        state.isAccessible = state.isAccessible && summary.isAccessible
        state.warnings.append(contentsOf: summary.warnings)
        state.hardLinkClaims.append(contentsOf: summary.hardLinkClaims)
    }

    nonisolated private func accumulateEnumeratedAtomicSummary(
        for url: URL,
        metadata: NodeMetadata,
        into state: AtomicDirectorySummaryState,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        workerLimit: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState,
        skipDescendants: () -> Void
    ) async throws {
        try cancellationCheck()
        guard !exclusionMatcher.excludes(url, isDirectory: metadata.isDirectory) else {
            if metadata.isDirectory {
                skipDescendants()
            }
            return
        }
        updateAtomicAccessibility(metadata.isReadable, in: state)

        guard metadata.isDirectory else {
            accumulateAtomicFile(metadata, url: url, into: state)
            return
        }

        guard metadata.isPackage, !treatPackagesAsDirectories else { return }

        if let packageSummary = try await summarize(
            at: url,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: true,
            workerLimit: workerLimit,
            ownerNodeID: state.ownerNodeID,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) {
            merge(packageSummary, into: state)
            skipDescendants()
        }
    }

    nonisolated private func updateAtomicAccessibility(_ isReadable: Bool, in state: AtomicDirectorySummaryState) {
        state.isAccessible = state.isAccessible && isReadable
    }

    nonisolated private func recordAtomicWarning(
        for url: URL,
        error: Error,
        in state: AtomicDirectorySummaryState
    ) {
        state.isAccessible = false
        state.warnings.append(ScanWarningFactory.makeWarning(for: url, error: error))
    }

    nonisolated private func accumulateAtomicFile(_ metadata: NodeMetadata, url: URL, into state: AtomicDirectorySummaryState) {
        state.allocatedSize += metadata.allocatedSize
        state.logicalSize += metadata.logicalSize

        if !metadata.isSymbolicLink {
            state.descendantFileCount += 1
        }

        if let claim = HardLinkDeduplicator.claim(for: metadata, ownerNodeID: state.ownerNodeID, path: url.path) {
            state.hardLinkClaims.append(claim)
        }
    }

    nonisolated private func makeAtomicSummary(from state: AtomicDirectorySummaryState) -> AtomicDirectorySummary {
        return AtomicDirectorySummary(
            allocatedSize: state.allocatedSize,
            logicalSize: state.logicalSize,
            descendantFileCount: state.descendantFileCount,
            isAccessible: state.isAccessible,
            warnings: state.warnings,
            hardLinkClaims: state.hardLinkClaims
        )
    }

    nonisolated func emitProgressHeartbeat(
        currentURL: URL,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) {
        metrics.currentPath = currentURL.path
        let now = Date()
        guard now.timeIntervalSince(emissionState.lastProgressEmission) >= 0.15 else { return }

        emissionState.lastProgressEmission = now
        continuation.yield(.progress(metrics))
    }
}
