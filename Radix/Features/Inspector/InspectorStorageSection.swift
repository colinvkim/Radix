import SwiftUI

struct InspectorStorageSection: View {
    let node: FileNodeRecord
    let parentName: String?
    let percentOfParent: String
    let percentOfScan: String

    var body: some View {
        Section("Key Stats") {
            InspectorKeyStats(
                allocatedSize: RadixFormatters.size(node.allocatedSize),
                percentOfParent: percentOfParent,
                percentOfScan: percentOfScan
            )
        }

        Section("Metadata") {
            LabeledContent("Kind") {
                Text(node.itemKind)
            }

            LabeledContent("Logical Size") {
                Text(RadixFormatters.size(node.logicalSize))
            }

            if let parentName {
                LabeledContent("Parent") {
                    Text(parentName)
                }
            }

            LabeledContent("Modified") {
                Text(RadixFormatters.date(node.lastModified))
            }

            LabeledContent("Access") {
                Text(node.accessDescription)
            }
        }
    }
}

private struct InspectorKeyStats: View {
    let allocatedSize: String
    let percentOfParent: String
    let percentOfScan: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                InspectorStatCard(title: "Allocated", value: allocatedSize)
                InspectorStatCard(title: "% Parent", value: percentOfParent)
                InspectorStatCard(title: "% Scan", value: percentOfScan)
            }

            VStack(spacing: 8) {
                InspectorStatCard(title: "Allocated", value: allocatedSize)
                InspectorStatCard(title: "% Parent", value: percentOfParent)
                InspectorStatCard(title: "% Scan", value: percentOfScan)
            }
        }
    }
}

private struct InspectorStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
