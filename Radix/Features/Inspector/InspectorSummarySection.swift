import SwiftUI

struct InspectorSummarySection: View {
    let node: FileNodeRecord

    var body: some View {
        Section {
            InspectorHeader(node: node)
        }
    }
}

private struct InspectorHeader: View {
    let node: FileNodeRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: node.systemImageName)
                .font(.title2)
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(node.name)
                    .font(.headline)
                    .lineLimit(3)

                if node.isSynthetic {
                    Text("Estimated storage that macOS reports as used but that Radix could not attribute to a regular file path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(node.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
