import SwiftUI

struct SunburstSegmentDrawingStyle {
    let fillBaseColor: Color
    let fillOpacity: Double
    let strokeColor: Color
    let strokeWidth: CGFloat

    var fillColor: Color {
        fillBaseColor.opacity(fillOpacity)
    }
}

enum SunburstChartStyler {
    private static let palette: [Color] = [
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPink)
    ]

    static func baseStyle(
        for segment: SunburstSegment
    ) -> SunburstSegmentDrawingStyle {
        if segment.isAggregate {
            return SunburstSegmentDrawingStyle(
                fillBaseColor: Color(nsColor: .tertiaryLabelColor),
                fillOpacity: 0.22,
                strokeColor: Color(nsColor: .separatorColor).opacity(0.55),
                strokeWidth: 1
            )
        }

        let baseOpacity = standardOpacity(for: segment)

        return SunburstSegmentDrawingStyle(
            fillBaseColor: baseColor(for: segment),
            fillOpacity: baseOpacity,
            strokeColor: Color(nsColor: .separatorColor).opacity(0.4),
            strokeWidth: 1
        )
    }

    static func selectionOverlayStyle(
        for segment: SunburstSegment,
        role: SunburstSelectionRole
    ) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetFillOpacity: Double
        let strokeColor: Color
        let strokeWidth: CGFloat

        switch role {
        case .ancestor:
            targetFillOpacity = min(base.fillOpacity + 0.04, 0.84)
            strokeColor = Color.white.opacity(0.22)
            strokeWidth = 1.5
        case .selected:
            targetFillOpacity = min(base.fillOpacity + 0.1, 0.9)
            strokeColor = Color.white.opacity(0.5)
            strokeWidth = 2.5
        }

        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetFillOpacity),
            strokeColor: strokeColor,
            strokeWidth: strokeWidth
        )
    }

    static func hoverOverlayStyle(for segment: SunburstSegment) -> SunburstSegmentDrawingStyle {
        let base = baseStyle(for: segment)
        let targetFillOpacity = hoverFillOpacity(for: segment)
        return SunburstSegmentDrawingStyle(
            fillBaseColor: base.fillBaseColor,
            fillOpacity: overlayOpacity(from: base.fillOpacity, to: targetFillOpacity),
            strokeColor: .primary.opacity(0.85),
            strokeWidth: 2.5
        )
    }

    private static func baseColor(for segment: SunburstSegment) -> Color {
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(segment.nodeID) {
            return Color(nsColor: .systemGray)
        }
        if segment.isAggregate {
            return Color(nsColor: .tertiaryLabelColor)
        }

        let paletteIndex = StablePaletteIndex.index(for: segment.colorKey, count: palette.count)
        return palette[paletteIndex]
    }

    private static func standardOpacity(for segment: SunburstSegment) -> Double {
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(segment.nodeID) {
            return 0.34
        }
        return max(0.24, 0.78 - (Double(segment.depth) * 0.09) - (segment.isAggregate ? 0.16 : 0))
    }

    private static func hoverFillOpacity(for segment: SunburstSegment) -> Double {
        if SunburstFreeSpaceVisualization.isFreeSpaceNodeID(segment.nodeID) {
            return 0.5
        }
        if segment.isAggregate {
            return 0.4
        }

        return min(standardOpacity(for: segment) + 0.18, 0.95)
    }

    private static func overlayOpacity(from baseOpacity: Double, to targetOpacity: Double) -> Double {
        guard targetOpacity > baseOpacity else { return 0 }
        let remainingOpacity = max(1 - baseOpacity, .leastNonzeroMagnitude)
        return min(max((targetOpacity - baseOpacity) / remainingOpacity, 0), 1)
    }
}
