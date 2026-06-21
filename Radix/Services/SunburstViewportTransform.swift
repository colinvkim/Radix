import CoreGraphics

struct SunburstViewportTransform: Equatable {
    static let identity = SunburstViewportTransform()
    static let minimumScale: CGFloat = 1
    static let maximumScale: CGFloat = 4

    var scale: CGFloat
    var offset: CGSize

    init(scale: CGFloat = Self.minimumScale, offset: CGSize = .zero) {
        let clampedScale = Self.clampedScale(scale, maximumScale: Self.maximumScale)
        self.scale = clampedScale
        self.offset = clampedScale <= Self.minimumScale ? .zero : offset
    }

    var isZoomed: Bool {
        scale > Self.minimumScale
    }

    func frame(for baseFrame: CGRect) -> CGRect {
        let size = CGSize(
            width: baseFrame.width * scale,
            height: baseFrame.height * scale
        )

        return CGRect(
            x: baseFrame.midX - (size.width / 2) + offset.width,
            y: baseFrame.midY - (size.height / 2) + offset.height,
            width: size.width,
            height: size.height
        )
    }

    func localPoint(for point: CGPoint, in baseFrame: CGRect) -> CGPoint? {
        localChartPoint(for: point, in: baseFrame)?.point
    }

    func localChartPoint(
        for point: CGPoint,
        in baseFrame: CGRect
    ) -> (point: CGPoint, size: CGSize)? {
        let frame = frame(for: baseFrame)
        guard frame.contains(point) else { return nil }

        return (
            CGPoint(
                x: point.x - frame.minX,
                y: point.y - frame.minY
            ),
            frame.size
        )
    }

    func zoomed(
        by factor: CGFloat,
        anchor: CGPoint?,
        in baseFrame: CGRect,
        maximumScale: CGFloat = Self.maximumScale
    ) -> SunburstViewportTransform {
        let nextScale = Self.clampedScale(scale * factor, maximumScale: maximumScale)
        guard nextScale > Self.minimumScale else {
            return .identity
        }

        var nextOffset = offset
        if let anchor {
            let currentCenter = CGPoint(
                x: baseFrame.midX + offset.width,
                y: baseFrame.midY + offset.height
            )
            let scaleRatio = nextScale / scale
            let nextCenter = CGPoint(
                x: anchor.x - ((anchor.x - currentCenter.x) * scaleRatio),
                y: anchor.y - ((anchor.y - currentCenter.y) * scaleRatio)
            )
            nextOffset = CGSize(
                width: nextCenter.x - baseFrame.midX,
                height: nextCenter.y - baseFrame.midY
            )
        }

        return SunburstViewportTransform(scale: nextScale, offset: nextOffset)
            .constrained(to: baseFrame, maximumScale: maximumScale)
    }

    func panned(by delta: CGSize, in baseFrame: CGRect) -> SunburstViewportTransform {
        guard isZoomed else { return .identity }

        let nextOffset = CGSize(
            width: offset.width + delta.width,
            height: offset.height + delta.height
        )

        return SunburstViewportTransform(scale: scale, offset: nextOffset)
            .constrained(to: baseFrame)
    }

    func constrained(
        to baseFrame: CGRect,
        maximumScale: CGFloat = Self.maximumScale
    ) -> SunburstViewportTransform {
        let nextScale = Self.clampedScale(scale, maximumScale: maximumScale)
        guard nextScale > Self.minimumScale else {
            return .identity
        }

        let maximumXOffset = max(0, baseFrame.width * (nextScale - 1) / 2)
        let maximumYOffset = max(0, baseFrame.height * (nextScale - 1) / 2)
        let nextOffset = CGSize(
            width: offset.width.clamped(to: -maximumXOffset...maximumXOffset),
            height: offset.height.clamped(to: -maximumYOffset...maximumYOffset)
        )

        return SunburstViewportTransform(scale: nextScale, offset: nextOffset)
    }

    private static func clampedScale(_ scale: CGFloat, maximumScale: CGFloat) -> CGFloat {
        scale.clamped(to: minimumScale...max(minimumScale, maximumScale))
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
