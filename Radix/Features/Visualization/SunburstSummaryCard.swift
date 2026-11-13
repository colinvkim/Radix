import SwiftUI

struct ChartSummary {
    let status: String?
    let title: String
    let value: String
    let detail: String

    var accessibilityDescription: String {
        [title, value, status, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

struct FloatingSummaryCard: View {
    let summary: ChartSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let status = summary.status {
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(summary.title)
                .font(.headline.weight(.semibold))
                .lineLimit(2)

            Text(summary.value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(summary.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .frame(width: 220, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
