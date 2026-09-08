import SwiftUI

struct SelectionInspectorActions {
    let selectNodeAfterViewUpdate: (String?) -> Void
    let selectAndFocusNodeAfterViewUpdate: (String) -> Void
    let expandSummarizedNode: (FileNodeRecord) -> Void
    let selectedFileActions: SelectedFileActions
    let addPrimarySelectionToDiscardPile: () -> Void
    let removeDiscardPileNode: (FileNodeRecord.ID) -> Void
    let presentDiscardPileReview: () -> Void
    let bulkFileActions: BulkFileActions
    let openFullDiskAccessSettings: () -> Void
}

struct SelectionInspectorView: View {
    @ObservedObject var scanState: ScanCoordinator
    @ObservedObject var navigation: WorkspaceNavigationModel
    let fullDiskAccessStatus: FullDiskAccessStatus
    let discardPileRootNodeIDs: Set<FileNodeRecord.ID>
    let actions: SelectionInspectorActions

    var body: some View {
        let selectedNodes = navigation.selectedNodes

        Group {
            if selectedNodes.count > 1 {
                multiSelectionView(selectedNodes)
            } else if let node = navigation.selectedNode {
                singleSelectionView(node)
            } else {
                InspectorNoSelectionView()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func multiSelectionView(_ selectedNodes: [FileNodeRecord]) -> some View {
        let summary = InspectorSelectionSummary(
            selectedNodes: selectedNodes,
            fileTreeStore: scanState.fileTreeStore
        )
        let availability = FileNodeActionAvailability(
            nodes: selectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
        let removalAvailability = FileNodeActionAvailability(
            nodes: summary.topLevelSelectedNodes,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
        let canMoveSelectionToTrash = summary.missingSelectedNodeCount == 0
            && removalAvailability.canMoveToTrash
        let warnings = relevantWarnings(for: summary.topLevelSelectedNodes)

        return InspectorMultiSelectionView(
            summary: summary,
            percentOfScan: selectionPercentOfScanText(summary) ?? "—",
            availability: availability,
            canMoveSelectionToTrash: canMoveSelectionToTrash,
            availabilityNotice: multiSelectionAvailabilityNotice(
                summary: summary,
                canMoveSelectionToTrash: canMoveSelectionToTrash
            ),
            warnings: warnings,
            fullDiskAccessAdvice: fullDiskAccessAdvice(for: warnings),
            actions: actions.bulkFileActions,
            openFullDiskAccessSettings: actions.openFullDiskAccessSettings
        )
    }

    private func singleSelectionView(_ node: FileNodeRecord) -> some View {
        let availability = FileNodeActionAvailability(
            node: node,
            activeTarget: scanState.selectedTarget,
            trashSafetyPolicy: scanState.trashSafetyPolicy,
            snapshotSource: scanState.snapshotSource
        )
        let warnings = relevantWarnings(for: [node])
        let largestChildren = largestChildren(of: node)
        let discardPileMembership = discardPileMembership(for: node)

        return VStack(spacing: 0) {
            Form {
                InspectorSummarySection(
                    node: node,
                    availability: availability,
                    allowsMoveToTrash: discardPileMembership == nil,
                    actions: actions.selectedFileActions
                )

                InspectorStorageSection(
                    allocatedSize: node.allocatedSize,
                    percentOfParent: selectedNodePercentOfParentText,
                    percentOfScan: selectedNodePercentOfScanText ?? "—"
                )

                if node.cloneIdentity != nil || node.mayShareDataBlocks {
                    InspectorSharedStorageSection(node: node)
                }

                if !warnings.isEmpty {
                    InspectorWarningsSection(
                        selectionName: node.displayName,
                        warnings: warnings,
                        fullDiskAccessAdvice: fullDiskAccessAdvice(for: warnings),
                        openFullDiskAccessSettings: actions.openFullDiskAccessSettings
                    )
                }

                if let discardPileMembership {
                    InspectorDiscardPileSection(
                        queuedRootName: discardPileMembership.isRoot
                            ? nil
                            : discardPileMembership.rootNode.name
                    )
                }

                if let notice = singleSelectionAvailabilityNotice(for: node) {
                    InspectorAvailabilityNotice(kind: notice)
                }

                if discardPileMembership == nil, canExpandSummarizedSelection(node) {
                    InspectorSummarizedSection {
                        actions.expandSummarizedNode(node)
                    }
                }

                if !largestChildren.isEmpty {
                    InspectorLargestChildrenSection(children: largestChildren) { child in
                        selectLargestChild(child)
                    }
                }

                if !node.isSynthetic {
                    InspectorDetailsSection(
                        node: node,
                        activeTarget: scanState.selectedTarget
                    )
                }
            }
            .formStyle(.grouped)
            .contentMargins(
                .horizontal,
                InspectorLayout.formHorizontalMargin,
                for: .scrollContent
            )

            if availability.canRevealInFinder
                || availability.canMoveToTrash
                || discardPileMembership != nil {
                InspectorActionBar(
                    revealAction: availability.canRevealInFinder
                        ? { actions.selectedFileActions.perform(.revealInFinder) }
                        : nil,
                    discardPileAction: discardPileAction(
                        for: node,
                        membership: discardPileMembership,
                        availability: availability
                    ),
                    discardPileTitle: discardPileActionTitle(
                        membership: discardPileMembership
                    ),
                    discardPileSystemImageName: discardPileMembership?.isRoot == true
                        ? "minus.circle"
                        : "checklist"
                )
            }
        }
    }

    private func discardPileMembership(
        for node: FileNodeRecord
    ) -> InspectorDiscardPileMembership? {
        guard !discardPileRootNodeIDs.isEmpty,
              let fileTreeStore = scanState.fileTreeStore,
              let rootNode = fileTreeStore.path(to: node.id).reversed().first(where: {
                  discardPileRootNodeIDs.contains($0.id)
              }) else {
            return nil
        }

        return InspectorDiscardPileMembership(
            rootNode: rootNode,
            isRoot: rootNode.id == node.id
        )
    }

    private func discardPileAction(
        for node: FileNodeRecord,
        membership: InspectorDiscardPileMembership?,
        availability: FileNodeActionAvailability
    ) -> (() -> Void)? {
        if let membership {
            if membership.isRoot {
                return { actions.removeDiscardPileNode(node.id) }
            }
            return actions.presentDiscardPileReview
        }

        return availability.canMoveToTrash
            ? actions.addPrimarySelectionToDiscardPile
            : nil
    }

    private func discardPileActionTitle(
        membership: InspectorDiscardPileMembership?
    ) -> String {
        guard let membership else {
            return String(
                localized: "Add to Discard Pile",
                comment: "Action for marking the selected item for possible deletion."
            )
        }
        if membership.isRoot {
            return String(
                localized: "Remove from Discard Pile",
                comment: "Inspector action for removing the selected item from the Discard Pile."
            )
        }
        return String(
            localized: "Review Discard Pile",
            comment: "Inspector action for reviewing the queued ancestor of the selected item."
        )
    }

    private func relevantWarnings(for nodes: [FileNodeRecord]) -> [ScanWarning] {
        guard let warnings = scanState.snapshot?.scanWarnings, !warnings.isEmpty else {
            return []
        }
        let rootPaths = nodes
            .filter { !$0.isSynthetic }
            .map { $0.url.standardizedFileURL.path }
        guard !rootPaths.isEmpty else { return [] }

        return warnings.filter { warning in
            let warningPath = URL(filePath: warning.path).standardizedFileURL.path
            return rootPaths.contains { rootPath in
                warningPath == rootPath || warningPath.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
            }
        }
    }

    private func fullDiskAccessAdvice(for warnings: [ScanWarning]) -> FullDiskAccessAdvice {
        PermissionAdvisor.fullDiskAccessAdvice(
            for: warnings,
            fullDiskAccessStatus: fullDiskAccessStatus,
            snapshotSource: scanState.snapshotSource
        )
    }

    private func largestChildren(of node: FileNodeRecord) -> [FileNodeRecord] {
        guard node.isDirectory, let fileTreeStore = scanState.fileTreeStore else {
            return []
        }
        return fileTreeStore.childrenPrefix(of: node.id, maxCount: 3)
    }

    private var selectedNodePercentOfParentText: String? {
        guard let selectedNode = navigation.selectedNode,
              let parent = navigation.selectedNodeParent else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: parent.allocatedSize)
    }

    private var selectedNodePercentOfScanText: String? {
        guard let selectedNode = navigation.selectedNode,
              let root = scanState.snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: selectedNode.allocatedSize, total: root.allocatedSize)
    }

    private func selectionPercentOfScanText(_ summary: InspectorSelectionSummary) -> String? {
        guard let root = scanState.snapshot?.root else { return nil }
        return RadixFormatters.percentage(part: summary.allocatedSize, total: root.allocatedSize)
    }

    private func singleSelectionAvailabilityNotice(
        for node: FileNodeRecord
    ) -> InspectorAvailabilityNoticeKind? {
        if scanState.snapshotSource.isImported {
            return .savedScan
        }
        if scanState.selectedTarget?.kind == .volume,
           scanState.selectedTarget?.id == node.id {
            return .scanRoot
        }
        if scanState.trashSafetyPolicy.blockReason(for: node.url) != nil {
            return .protectedLocation
        }
        return nil
    }

    private func multiSelectionAvailabilityNotice(
        summary: InspectorSelectionSummary,
        canMoveSelectionToTrash: Bool
    ) -> InspectorAvailabilityNoticeKind? {
        if scanState.snapshotSource.isImported {
            return .savedScan
        }
        if summary.selectedNodes.contains(where: { !$0.supportsFileActions }) {
            return .limitedSelection
        }
        if summary.missingSelectedNodeCount == 0, !canMoveSelectionToTrash {
            return .protectedSelection
        }
        return nil
    }

    private func canExpandSummarizedSelection(_ node: FileNodeRecord) -> Bool {
        node.isAutoSummarized && !scanState.snapshotSource.isImported
    }

    private func selectLargestChild(_ child: FileNodeRecord) {
        guard discardPileMembership(for: child) == nil,
              child.isDirectory,
              scanState.fileTreeStore?.containsChildren(id: child.id) == true else {
            actions.selectNodeAfterViewUpdate(child.id)
            return
        }

        actions.selectAndFocusNodeAfterViewUpdate(child.id)
    }
}

private struct InspectorDiscardPileMembership {
    let rootNode: FileNodeRecord
    let isRoot: Bool
}
