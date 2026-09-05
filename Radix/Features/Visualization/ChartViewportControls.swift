import SwiftUI

/// Keeps viewport state and animation policy local to each chart view.
struct ChartViewportState: DynamicProperty {
    @State private(set) var transform = ChartViewportTransform.identity
    @State private var settledLayoutID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func setTransform(_ nextTransform: ChartViewportTransform, animated: Bool = false) {
        guard transform != nextTransform else { return }
        let update = { transform = nextTransform }
        if animated {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16), update)
        } else {
            update()
        }
    }

    /// Initial presentation keeps its viewport; a different layout resets it.
    @discardableResult
    func reset(for layoutID: String) -> Bool {
        guard settledLayoutID != layoutID else { return false }
        let shouldReset = settledLayoutID != nil
        settledLayoutID = layoutID
        if shouldReset { setTransform(.identity) }
        return shouldReset
    }

    @discardableResult
    func perform(_ action: ChartViewportAction, in frame: CGRect, canZoom: Bool) -> Bool {
        let nextTransform: ChartViewportTransform
        switch action {
        case .zoomIn, .zoomOut:
            guard canZoom else { return false }
            nextTransform = transform.zoomed(
                by: action == .zoomIn ? ChartViewportTransform.zoomInFactor : ChartViewportTransform.zoomOutFactor,
                anchor: nil,
                in: frame
            )
        case .reset:
            nextTransform = .identity
        }
        setTransform(nextTransform, animated: true)
        return true
    }
}

struct ChartViewportControls: View {
    let transform: ChartViewportTransform
    let onAction: (ChartViewportAction) -> Void
    @State private var showsControls = false

    private var zoomText: String {
        "\(Int((transform.scale * 100).rounded()))%"
    }

    var body: some View {
        let accessibilityLabel = String(
            localized: "Zoom Controls",
            comment: "Accessibility label for opening the disk map zoom controls."
        )

        Button {
            showsControls.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(zoomText)
        .help(accessibilityLabel)
        .popover(isPresented: $showsControls, arrowEdge: .trailing) {
            controlRow
                .padding(10)
        }
    }

    private var controlRow: some View {
        HStack(spacing: 6) {
            controlButton(
                systemName: "minus.magnifyingglass",
                accessibilityLabel: String(localized: "Zoom Out", comment: "Accessibility label for zooming out of the disk map."),
                action: { onAction(.zoomOut) }
            )
            .disabled(!transform.isZoomed)

            Text(zoomText)
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 42)

            controlButton(
                systemName: "plus.magnifyingglass",
                accessibilityLabel: String(localized: "Zoom In", comment: "Accessibility label for zooming into the disk map."),
                action: { onAction(.zoomIn) }
            )
            .disabled(transform.scale >= ChartViewportTransform.maximumScale)

            Divider()
                .frame(height: 16)

            controlButton(
                systemName: "arrow.counterclockwise",
                accessibilityLabel: String(localized: "Reset Zoom", comment: "Accessibility label for resetting the disk map zoom."),
                action: { onAction(.reset) }
            )
            .disabled(!transform.isZoomed)
        }
    }

    private func controlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}
