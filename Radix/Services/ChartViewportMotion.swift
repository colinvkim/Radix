import CoreGraphics

/// A single presentation transform shared by chart drawing and hit testing.
nonisolated struct ChartViewportMotion {
    private(set) var transform = ChartViewportTransform.identity
    private(set) var target = ChartViewportTransform.identity
    private var animation: Transition?

    var isAnimating: Bool { animation != nil }

    mutating func move(to target: ChartViewportTransform, at time: Double, duration: Double) {
        self.target = target
        guard duration > 0, transform != target else {
            transform = target
            animation = nil
            return
        }
        animation = Transition(from: transform, startedAt: time, duration: duration)
    }

    mutating func advance(to time: Double) {
        guard let animation else { return }
        let progress = min(max((time - animation.startedAt) / animation.duration, 0), 1)
        guard progress < 1 else {
            transform = target
            self.animation = nil
            return
        }
        let remaining = 1 - progress
        let fraction = CGFloat(1 - remaining * remaining * remaining)
        let from = animation.from
        transform = ChartViewportTransform(
            scale: from.scale + (target.scale - from.scale) * fraction,
            offset: CGSize(
                width: from.offset.width + (target.offset.width - from.offset.width) * fraction,
                height: from.offset.height + (target.offset.height - from.offset.height) * fraction
            )
        )
    }

    mutating func stop() {
        target = transform
        animation = nil
    }

    private struct Transition {
        let from: ChartViewportTransform
        let startedAt: Double
        let duration: Double
    }
}
