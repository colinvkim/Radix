import AppKit
import Combine
import QuartzCore
import SwiftUI

struct ChartViewportState: DynamicProperty {
    @StateObject private var animator = ChartViewportAnimator()
    @State private var settledLayoutID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var transform: ChartViewportTransform { animator.transform }
    var isAnimating: Bool { animator.isAnimating }

    func attach(to view: NSView) { animator.interactionView = view }
    func stopAnimation() { animator.stop() }

    func setTransform(_ nextTransform: ChartViewportTransform, animated: Bool = false) {
        animator.move(to: nextTransform, duration: animated && !reduceMotion ? 0.16 : 0)
    }

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
            nextTransform = animator.target.zoomed(
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

@MainActor
private final class ChartViewportAnimator: ObservableObject {
    @Published private var motion = ChartViewportMotion()
    weak var interactionView: NSView?
    private var displayLink: CADisplayLink?

    var transform: ChartViewportTransform { motion.transform }
    var target: ChartViewportTransform { motion.target }
    var isAnimating: Bool { motion.isAnimating }

    func move(to target: ChartViewportTransform, duration: Double) {
        guard motion.transform != target || motion.isAnimating else { return }
        if duration > 0, motion.isAnimating, motion.target == target { return }
        var next = motion
        next.move(to: target, at: CACurrentMediaTime(), duration: duration)
        publish(next)
        guard motion.isAnimating else {
            invalidateDisplayLink()
            return
        }
        guard displayLink == nil else { return }
        let receiver = DisplayLinkReceiver(owner: self)
        let link = interactionView?.displayLink(target: receiver, selector: #selector(DisplayLinkReceiver.tick(_:)))
            ?? NSScreen.main?.displayLink(target: receiver, selector: #selector(DisplayLinkReceiver.tick(_:)))
        guard let link else {
            var settled = motion
            settled.move(to: target, at: CACurrentMediaTime(), duration: 0)
            publish(settled)
            return
        }
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        invalidateDisplayLink()
        var next = motion
        next.stop()
        publish(next)
    }

    private func tick(_ link: CADisplayLink) {
        var next = motion
        next.advance(to: link.targetTimestamp)
        publish(next)
        if !motion.isAnimating { invalidateDisplayLink() }
    }

    private func publish(_ next: ChartViewportMotion) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { motion = next }
    }

    private func invalidateDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    // CADisplayLink retains its target. Keep the chart's lifetime independent of
    // the display link, including if its window disappears mid-animation.
    private final class DisplayLinkReceiver: NSObject {
        weak var owner: ChartViewportAnimator?

        init(owner: ChartViewportAnimator) { self.owner = owner }

        @objc func tick(_ link: CADisplayLink) {
            guard let owner else {
                link.invalidate()
                return
            }
            owner.tick(link)
        }
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
