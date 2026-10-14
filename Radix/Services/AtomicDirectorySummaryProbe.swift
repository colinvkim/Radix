import Foundation

nonisolated private struct AtomicProbeCancellation: Error {
    let underlyingError: Error
}

nonisolated private struct BulkAtomicProbeFrame: @unchecked Sendable {
    var workItem: AtomicSummaryWorkItem
    var reusableEntries: [DirectoryEntry] = []
    var enumeratedItemCount = 0
    let retainsReusableListing: Bool
}

extension AtomicDirectorySummarizer {
    private nonisolated static func directoryOnlyProbeLimit(minFileCount: Int) -> Int {
        min(max(64, minFileCount / 4), 512)
    }

    nonisolated static func isNodeDependencyLayoutDirectory(at url: URL) -> Bool {
        let name = url.lastPathComponent
        if name == "node_modules" || name == ".pnpm" {
            return true
        }

        guard name.hasPrefix("@") else { return false }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName == "node_modules" || parentName == ".pnpm"
    }

    nonisolated func shouldRunDescendantAtomicProbe(
        childEntries: [DirectoryEntry],
        minFileCount: Int,
        isNodeDependencyLayout: Bool
    ) -> Bool {
        if isNodeDependencyLayout {
            return true
        }

        guard childEntries.contains(where: { childEntry in
            childEntry.metadata?.isDirectory ?? childEntry.url.hasDirectoryPath
        }) else {
            return false
        }

        // Sparse parents are cheaper to traverse normally; dense descendants can still summarize themselves.
        let minimumImmediateEntries = max(1, min(minFileCount, minFileCount / 10))
        return childEntries.count >= minimumImmediateEntries
    }

    nonisolated func immediateChildrenSuggestAtomicDirectory(
        _ childEntries: [DirectoryEntry],
        maxAverageFileSize: Int64,
        cancellationCheck: CancellationCheck
    ) throws -> Bool {
        try cancellationCheck()
        let sampleSize = min(100, childEntries.count)
        let step = max(1, childEntries.count / sampleSize)
        var sampleTotalSize: Int64 = 0
        var sampleFileCount = 0

        for index in stride(from: 0, to: childEntries.count, by: step).prefix(sampleSize) {
            try cancellationCheck()
            let childEntry = childEntries[index]
            guard let childMetadata = childEntry.metadata else {
                return false
            }

            if !childMetadata.isDirectory {
                sampleTotalSize += childMetadata.logicalSize
                sampleFileCount += 1
            }
        }

        guard sampleFileCount > 0 else { return false }
        return (sampleTotalSize / Int64(sampleFileCount)) <= maxAverageFileSize
    }

    nonisolated func descendantAtomicProbeProfile(
        at url: URL,
        rootEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> AtomicDirectoryProbeOutcome {
        try cancellationCheck()
        #if DEBUG
        let probeStart = diagnostics?.start()
        #endif
        var visitedItems = 0
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        #if DEBUG
        defer {
            diagnostics?.record(
                operation: "atomic.probe",
                url: url,
                startedAt: probeStart,
                itemCount: visitedItems,
                detail: "files=\(profile.observedFileCount) dirs=\(profile.observedDirectoryCount) nodeDeps=\(profile.observedNodeDependencyLayout)"
            )
        }
        #endif
        let maxVisitedItems = isNodeDependencyLayout
            ? max(5_000, minFileCount * 8)
            : max(1_000, minFileCount)
        let hasActiveExclusions = !exclusionMatcher.isEmpty

        if let bulkResult = try bulkDescendantAtomicProbeProfile(
            at: url,
            rootEntries: rootEntries,
            rootMetadata: rootMetadata,
            includeHiddenFiles: includeHiddenFiles,
            treatPackagesAsDirectories: treatPackagesAsDirectories,
            isNodeDependencyLayout: isNodeDependencyLayout,
            minFileCount: minFileCount,
            maxAverageFileSize: maxAverageFileSize,
            maxVisitedItems: maxVisitedItems,
            exclusionMatcher: exclusionMatcher,
            cancellationCheck: cancellationCheck,
            metrics: &metrics,
            continuation: continuation,
            emissionState: &emissionState
        ) {
            visitedItems = bulkResult.outcome.visitedItemCount
            profile = bulkResult.outcome.profile
            return bulkResult.outcome
        }

        var enumeratorOptions: FileManager.DirectoryEnumerationOptions = []
        if !includeHiddenFiles {
            enumeratorOptions.insert(.skipsHiddenFiles)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: ScanMetadataLoader.atomicProbeResourceKeys,
            options: enumeratorOptions,
            errorHandler: { _, _ in true }
        ) else {
            return AtomicDirectoryProbeOutcome(
                profile: profile,
                resumeState: nil,
                visitedItemCount: visitedItems
            )
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
            guard visitedItems <= maxVisitedItems else {
                return AtomicDirectoryProbeOutcome(
                    profile: profile,
                    resumeState: nil,
                    visitedItemCount: visitedItems
                )
            }

            let hintedIsDirectory = childURL.hasDirectoryPath
            let childPath = hasActiveExclusions ? childURL.path : nil
            if let datalessStatus = metadataLoader.datalessStatus(at: childURL) {
                if datalessStatus.isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            if let childPath,
               exclusionMatcher.excludesKnownNormalizedPath(
                   childPath,
                   isDirectory: hintedIsDirectory
               ) {
                if hintedIsDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            do {
                let values = try childURL.resourceValues(forKeys: ScanMetadataLoader.atomicProbeResourceKeySet)
                let isDirectory = values.isDirectory ?? false
                let isSymbolicLink = values.isSymbolicLink ?? false

                if isDirectory != hintedIsDirectory,
                   let childPath,
                   exclusionMatcher.excludesKnownNormalizedPath(childPath, isDirectory: isDirectory) {
                    if isDirectory {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if isDirectory, volumeBoundaryPolicy.requiresChildDeviceIdentity {
                    let childIdentity = try metadataLoader.fileSystemIdentity(at: childURL)
                    if volumeBoundaryPolicy.shouldStopDescent(
                        childDeviceID: childIdentity.fileSystemDeviceID
                    ) {
                        enumerator.skipDescendants()
                        continue
                    }
                }

                if Self.isNodeDependencyLayoutDirectory(at: childURL) {
                    profile.observedNodeDependencyLayout = true
                }

                guard !isDirectory else {
                    profile.observedDirectoryCount += 1
                    // Dense file caches reveal files quickly; directory-only trees should traverse normally.
                    if !isNodeDependencyLayout,
                       profile.observedFileCount == 0,
                       profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                        return AtomicDirectoryProbeOutcome(
                            profile: profile,
                            resumeState: nil,
                            visitedItemCount: visitedItems
                        )
                    }
                    continue
                }
                guard !isSymbolicLink else { continue }

                profile.totalSampledLogicalSize = ScanIntegerMath.addingClamped(
                    profile.totalSampledLogicalSize,
                    Int64(values.totalFileSize ?? values.fileSize ?? 0)
                )
                profile.observedFileCount += 1

                if profile.suggestsAtomicDirectory(
                    minFileCount: minFileCount,
                    maxAverageFileSize: maxAverageFileSize
                ) {
                    return AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: nil,
                        visitedItemCount: visitedItems
                    )
                }
                // Once minimum sample is large-file-biased, skip summary and keep full detail.
                if profile.observedFileCount >= minFileCount {
                    return AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: nil,
                        visitedItemCount: visitedItems
                    )
                }
            } catch {
                return AtomicDirectoryProbeOutcome(
                    profile: profile,
                    resumeState: nil,
                    visitedItemCount: visitedItems
                )
            }
        }

        return AtomicDirectoryProbeOutcome(
            profile: profile,
            resumeState: nil,
            visitedItemCount: visitedItems
        )
    }

    /// Mirrors `FileManager.DirectoryEnumerator`'s depth-first probe using
    /// immediate-child bulk metadata batches. Returning `nil` selects the
    /// Foundation compatibility path above on unsupported filesystems.
    private nonisolated func bulkDescendantAtomicProbeProfile(
        at url: URL,
        rootEntries: [DirectoryEntry],
        rootMetadata: NodeMetadata,
        includeHiddenFiles: Bool,
        treatPackagesAsDirectories: Bool,
        isNodeDependencyLayout: Bool,
        minFileCount: Int,
        maxAverageFileSize: Int64,
        maxVisitedItems: Int,
        exclusionMatcher: ScanExclusionMatcher,
        cancellationCheck: CancellationCheck,
        metrics: inout ScanMetrics,
        continuation: AsyncThrowingStream<ScanProgressEvent, Error>.Continuation,
        emissionState: inout ScanEmissionState
    ) throws -> (outcome: AtomicDirectoryProbeOutcome, visitedItems: Int)? {
        var profile = AtomicDirectoryProbeProfile(observedNodeDependencyLayout: isNodeDependencyLayout)
        var visitedItems = 0
        var partial = AtomicDirectorySummaryPartial()
        partial.updateAccessibility(rootMetadata.isReadable)
        var reusableDirectoryListings: [String: AtomicDirectoryProbeListing] = [:]
        var fullyEnumerated = true
        let hasActiveExclusions = !exclusionMatcher.isEmpty
        // The caller already enumerated and classified the root directory.
        // A successful probe hands these frames directly to the summary queue.
        var frames = [BulkAtomicProbeFrame(
            workItem: AtomicSummaryWorkItem(
                url: url,
                treatPackagesAsDirectories: treatPackagesAsDirectories,
                ownerNodeID: url.path,
                volumeBoundaryPolicy: volumeBoundaryPolicy,
                bufferedEntries: rootEntries,
                needsCursor: false
            ),
            retainsReusableListing: false
        )]
        var activeCursorCount = 0

        while !frames.isEmpty {
            try cancellationCheck()
            let frameIndex = frames.index(before: frames.endIndex)
            if frames[frameIndex].workItem.nextEntryIndex
                >= frames[frameIndex].workItem.bufferedEntries.count {
                if frames[frameIndex].workItem.cursor == nil,
                   frames[frameIndex].workItem.needsCursor {
                    do {
                        if activeCursorCount >= 64 {
                            guard let childResult = try BulkDirectoryEnumerator.directoryEntries(
                                at: frames[frameIndex].workItem.url,
                                includeHiddenFiles: includeHiddenFiles,
                                loadsPackageMetadata: !frames[frameIndex].workItem.treatPackagesAsDirectories,
                                metadataLoader: metadataLoader,
                                cancellationCheck: {
                                    do {
                                        try cancellationCheck()
                                    } catch {
                                        throw AtomicProbeCancellation(underlyingError: error)
                                    }
                                }
                            ) else {
                                return nil
                            }
                            frames[frameIndex].workItem.bufferedEntries = childResult.entries
                            frames[frameIndex].workItem.nextEntryIndex = 0
                            frames[frameIndex].workItem.needsCursor = false
                            if frames[frameIndex].retainsReusableListing {
                                frames[frameIndex].reusableEntries = childResult.entries
                                frames[frameIndex].enumeratedItemCount = childResult.enumeratedItemCount
                            }
                            continue
                        }
                        frames[frameIndex].workItem.cursor = try BulkDirectoryEnumerator.makeCursor(
                            at: frames[frameIndex].workItem.url,
                            includeHiddenFiles: includeHiddenFiles,
                            loadsPackageMetadata: !frames[frameIndex].workItem.treatPackagesAsDirectories,
                            metadataLoader: metadataLoader,
                            cancellationCheck: {
                                do {
                                    try cancellationCheck()
                                } catch {
                                    throw AtomicProbeCancellation(underlyingError: error)
                                }
                            }
                        )
                        activeCursorCount += 1
                        frames[frameIndex].workItem.needsCursor = false
                    } catch let cancellation as AtomicProbeCancellation {
                        throw cancellation.underlyingError
                    } catch {
                        partial.recordWarning(for: frames[frameIndex].workItem.url, error: error)
                        fullyEnumerated = false
                        frames.removeLast()
                        continue
                    }
                }

                if let cursor = frames[frameIndex].workItem.cursor {
                    do {
                        if let batch = try cursor.nextBatch(cancellationCheck: {
                            do {
                                try cancellationCheck()
                            } catch {
                                throw AtomicProbeCancellation(underlyingError: error)
                            }
                        }) {
                            frames[frameIndex].workItem.bufferedEntries = batch.entries
                            frames[frameIndex].workItem.nextEntryIndex = 0
                            if frames[frameIndex].retainsReusableListing {
                                frames[frameIndex].reusableEntries.append(contentsOf: batch.entries)
                                frames[frameIndex].enumeratedItemCount += batch.enumeratedItemCount
                            }
                            continue
                        }
                    } catch let cancellation as AtomicProbeCancellation {
                        throw cancellation.underlyingError
                    } catch BulkDirectoryEnumerator.StreamError.unavailable {
                        return nil
                    } catch {
                        return nil
                    }
                }
                let completedFrame = frames.removeLast()
                if completedFrame.workItem.cursor != nil {
                    assert(activeCursorCount > 0)
                    activeCursorCount -= 1
                }
                if completedFrame.retainsReusableListing {
                    reusableDirectoryListings[completedFrame.workItem.url.path] = AtomicDirectoryProbeListing(
                        entries: completedFrame.reusableEntries,
                        enumeratedItemCount: completedFrame.enumeratedItemCount
                    )
                }
                continue
            }

            let entry = frames[frameIndex].workItem.bufferedEntries[
                frames[frameIndex].workItem.nextEntryIndex
            ]
            frames[frameIndex].workItem.nextEntryIndex += 1
            visitedItems += 1
            if visitedItems == 1 || visitedItems.isMultiple(of: 64) {
                emitProgressHeartbeat(
                    currentURL: entry.url,
                    metrics: &metrics,
                    continuation: continuation,
                    emissionState: &emissionState
                )
            }
            guard visitedItems <= maxVisitedItems else {
                return (
                    AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: nil,
                        visitedItemCount: visitedItems,
                        reusableDirectoryListings: reusableDirectoryListings
                    ),
                    visitedItems
                )
            }

            guard let metadata = entry.metadata else {
                return (
                    AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: nil,
                        visitedItemCount: visitedItems,
                        reusableDirectoryListings: reusableDirectoryListings
                    ),
                    visitedItems
                )
            }
            guard !metadata.isDataless else { continue }
            if hasActiveExclusions,
               exclusionMatcher.excludesKnownNormalizedPath(
                   entry.url.path,
                   isDirectory: metadata.isDirectory
               ) {
                continue
            }

            if metadata.isDirectory,
               let boundaryError = frames[frameIndex].workItem.volumeBoundaryPolicy
                   .descentBoundaryError(
                       for: entry.url,
                       childDeviceID: metadata.fileIdentity?.fileSystemDeviceID
                   ) {
                partial.recordWarning(for: entry.url, error: boundaryError)
                continue
            }

            if Self.isNodeDependencyLayoutDirectory(at: entry.url) {
                profile.observedNodeDependencyLayout = true
            }
            partial.updateAccessibility(metadata.isReadable)

            if metadata.isDirectory {
                profile.observedDirectoryCount += 1
                if !isNodeDependencyLayout,
                   profile.observedFileCount == 0,
                   profile.observedDirectoryCount >= Self.directoryOnlyProbeLimit(minFileCount: minFileCount) {
                    return (
                        AtomicDirectoryProbeOutcome(
                            profile: profile,
                            resumeState: nil,
                            visitedItemCount: visitedItems,
                            reusableDirectoryListings: reusableDirectoryListings
                        ),
                        visitedItems
                    )
                }

                let isTraversablePackageSymlink = metadata.isSymbolicLink
                    && metadata.isPackage
                    && !frames[frameIndex].workItem.treatPackagesAsDirectories
                if !metadata.isSymbolicLink || isTraversablePackageSymlink {
                    let treatsPackagesAsDirectories = metadata.isPackage
                        ? true
                        : frames[frameIndex].workItem.treatPackagesAsDirectories
                    frames.append(
                        BulkAtomicProbeFrame(
                            workItem: AtomicSummaryWorkItem(
                                url: entry.url,
                                treatPackagesAsDirectories: treatsPackagesAsDirectories,
                                ownerNodeID: frames[frameIndex].workItem.ownerNodeID,
                                volumeBoundaryPolicy: frames[frameIndex].workItem
                                    .volumeBoundaryPolicy
                            ),
                            retainsReusableListing: !treatsPackagesAsDirectories
                        )
                    )
                }
                continue
            }
            partial.accumulateFile(
                metadata,
                url: entry.url,
                ownerNodeID: frames[frameIndex].workItem.ownerNodeID
            )
            guard !metadata.isSymbolicLink else { continue }

            profile.totalSampledLogicalSize = ScanIntegerMath.addingClamped(
                profile.totalSampledLogicalSize,
                metadata.logicalSize
            )
            profile.observedFileCount += 1
            if profile.suggestsAtomicDirectory(
                minFileCount: minFileCount,
                maxAverageFileSize: maxAverageFileSize
            ) {
                for index in frames.indices {
                    frames[index].workItem.requiresRootRestartOnFallback = true
                }
                return (
                    AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: AtomicDirectoryProbeResumeState(
                            partial: partial,
                            workItems: frames.map(\.workItem),
                            visitedItemCount: visitedItems
                        ),
                        visitedItemCount: visitedItems
                    ),
                    visitedItems
                )
            }
            if profile.observedFileCount >= minFileCount {
                return (
                    AtomicDirectoryProbeOutcome(
                        profile: profile,
                        resumeState: nil,
                        visitedItemCount: visitedItems,
                        reusableDirectoryListings: reusableDirectoryListings
                    ),
                    visitedItems
                )
            }
        }

        return (
            AtomicDirectoryProbeOutcome(
                profile: profile,
                resumeState: nil,
                visitedItemCount: visitedItems,
                reusableDirectoryListings: reusableDirectoryListings,
                fullyExhausted: fullyEnumerated
            ),
            visitedItems
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
        summaryPool.reportCurrentPath(
            currentURL.path,
            continuation: continuation,
        )
    }
}
