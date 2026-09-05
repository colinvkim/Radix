//
//  ChartLayoutFailureBanner.swift
//  Radix
//

import SwiftUI

struct ChartLoadingOverlay<RequestID: Hashable>: View {
    let presentation: ChartLayoutPresentationState
    let showsEmptyProgress: Bool
    let requestID: RequestID
    @State private var progressRequestID: RequestID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if presentation.shouldObscureRenderedLayout {
                Color(nsColor: .windowBackgroundColor)
                    .opacity(0.28)

                if presentation.isAwaitingLayout, progressRequestID == requestID {
                    ProgressView("Loading Disk Map…")
                        .controlSize(.small)
                        .transition(.opacity)
                }
            } else if showsEmptyProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .allowsHitTesting(false)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.12),
            value: progressRequestID
        )
        .task(id: presentation.isAwaitingLayout ? requestID : nil) {
            progressRequestID = nil
            guard presentation.isAwaitingLayout else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            progressRequestID = requestID
        }
    }
}

struct ChartLayoutFailureBanner: View {
    let failure: ChartLayoutFailure
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Couldn’t Load Disk Map", tableName: "Interface")
                    .font(.headline)
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: retry) {
                Text("Retry", tableName: "Interface")
            }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(
                    Text("Attempts to load the disk map again.", tableName: "Interface")
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Disk map layout failed", tableName: "Interface"))
    }
}
