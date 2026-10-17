import SwiftUI

struct InspectorStorageSection: View {
    let allocatedSize: Int64
    let percentOfParent: String?
    let percentOfScan: String
    var notes: [String] = []

    var body: some View {
        let allocatedSizeText = RadixFormatters.size(allocatedSize)

        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(allocatedSizeText)
                        .font(.title2.weight(.semibold).monospacedDigit())
                        .accessibilityLabel(
                            String(
                                localized: "Allocated size \(allocatedSizeText)",
                                comment: "Accessibility label for the allocated storage value in the Inspector."
                            )
                        )

                    Text("Allocated")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if allocatedSize > 0 {
                    HStack(spacing: 18) {
                        if let percentOfParent {
                            InspectorPercentageMetric(value: percentOfParent, label: "of parent")
                        }

                        InspectorPercentageMetric(value: percentOfScan, label: "of scan")
                    }
                }

                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
    }
}

private struct InspectorPercentageMetric: View {
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct InspectorSharedStorageSection: View {
    let node: FileNodeRecord

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "doc.on.doc.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: LocalizedStringKey {
        node.cloneIdentity == nil ? "May share APFS storage" : "Shared APFS storage"
    }

    private var message: String {
        let logicalSize = RadixFormatters.size(node.logicalSize)
        if node.cloneIdentity != nil {
            return String(
                localized: "\(logicalSize) logical size. Radix counts shared bytes once across clones, so deleting this file may free less than its apparent size.",
                comment: "Inspector explanation for an APFS clone's logical size and attributed allocated storage."
            )
        }
        return String(
            localized: "\(logicalSize) logical size. Parts of this file may share storage; exact shared and reclaimable bytes aren’t available from macOS.",
            comment: "Inspector explanation for a file that may share APFS storage."
        )
    }
}

struct InspectorMultiSharedStorageSection: View {
    let containsKnownClones: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: "doc.on.doc.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Some selected files may share APFS storage. Allocated totals reflect Radix’s storage attribution and may differ from the space reclaimed by deletion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: LocalizedStringKey {
        containsKnownClones ? "Shared APFS storage" : "May share APFS storage"
    }
}

struct InspectorDiscardPileSection: View {
    let queuedRootName: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("In Discard Pile", systemImage: "checklist")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var message: String {
        if let queuedRootName {
            return String(
                localized: "\(queuedRootName) is in the Discard Pile, so this item is included with it.",
                comment: "Inspector explanation for an item included because its ancestor is in the Discard Pile."
            )
        }

        return String(
            localized: "This item is marked for review. It remains on disk until you move the Discard Pile to Trash.",
            comment: "Inspector explanation for an item directly added to the Discard Pile."
        )
    }
}

enum InspectorAvailabilityNoticeKind {
    case savedScan
    case scanRoot
    case protectedLocation
    case protectedSelection
    case limitedSelection
    case readOnlyMode
}

struct InspectorAvailabilityNotice: View {
    let kind: InspectorAvailabilityNoticeKind

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    title
                } icon: {
                    Image(systemName: systemImage)
                }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(color)

                message
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var title: Text {
        switch kind {
        case .savedScan: Text("Saved scan")
        case .scanRoot: Text("Scan root")
        case .protectedLocation: Text("Protected location")
        case .protectedSelection: Text("Protected selection")
        case .limitedSelection: Text("Limited actions")
        case .readOnlyMode: Text("Read-only mode", tableName: "Interface")
        }
    }

    private var message: Text {
        switch kind {
        case .savedScan:
            Text("This selection comes from a saved scan. Removal actions are unavailable.")
        case .scanRoot:
            Text("The scanned volume itself cannot be added to the Discard Pile or moved to Trash.")
        case .protectedLocation:
            Text("This location is protected from removal. You can still open it or reveal it in Finder.")
        case .protectedSelection:
            Text("Some selected items are protected from removal. You can still reveal them in Finder.")
        case .limitedSelection:
            Text("Some selected items do not represent regular file paths, so file actions are unavailable.")
        case .readOnlyMode:
            Text(
                "Read-only mode is enabled. Turn it off in Settings to use file cleanup actions.",
                tableName: "Localizable"
            )
        }
    }

    private var systemImage: String {
        switch kind {
        case .savedScan: "archivebox.fill"
        case .scanRoot: "externaldrive.fill"
        case .protectedLocation: "lock.fill"
        case .protectedSelection: "lock.fill"
        case .limitedSelection: "exclamationmark.triangle.fill"
        case .readOnlyMode: "lock.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .savedScan, .scanRoot, .readOnlyMode: .accentColor
        case .protectedLocation, .protectedSelection, .limitedSelection: .orange
        }
    }
}

struct InspectorSummarizedSection: View {
    let expand: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Contents summarized", systemImage: "square.stack.3d.up.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)

                Text("Radix grouped this folder during the scan. Expand it to inspect individual items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    expand()
                } label: {
                    Label("Expand Fully", systemImage: "arrowshape.turn.up.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

struct InspectorDetailsSection: View {
    let node: FileNodeRecord
    let activeTarget: ScanTarget?

    var body: some View {
        Section("Details") {
            LabeledContent("Kind") {
                Text(node.itemKind(activeTarget: activeTarget))
            }

            LabeledContent("Modified") {
                Text(RadixFormatters.date(node.lastModified))
            }
        }
    }
}
