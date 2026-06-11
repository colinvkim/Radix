import SwiftUI

struct SunburstBaseCanvas: View, Equatable {
    let segments: [SunburstSegment]
    let renderVersion: Int

    static func == (lhs: SunburstBaseCanvas, rhs: SunburstBaseCanvas) -> Bool {
        lhs.renderVersion == rhs.renderVersion
    }

    var body: some View {
        Canvas { context, size in
            for segment in segments {
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.baseStyle(for: segment)
                context.fill(path, with: .color(style.fillColor))
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct SunburstSelectionOverlay: View, Equatable {
    let segments: [SunburstSelectionOverlaySegment]

    var body: some View {
        Canvas { context, size in
            for overlaySegment in segments {
                let segment = overlaySegment.segment
                let path = SunburstRenderer.path(for: segment, in: size)
                let style = SunburstChartStyler.selectionOverlayStyle(
                    for: segment,
                    role: overlaySegment.role
                )
                if style.fillOpacity > 0 {
                    context.fill(path, with: .color(style.fillColor))
                }
                context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
            }
        }
    }
}

struct SunburstHoverOverlay: View, Equatable {
    let segment: SunburstSegment?

    var body: some View {
        Canvas { context, size in
            guard let segment else { return }

            let path = SunburstRenderer.path(for: segment, in: size)
            let style = SunburstChartStyler.hoverOverlayStyle(for: segment)
            if style.fillOpacity > 0 {
                context.fill(path, with: .color(style.fillColor))
            }
            context.stroke(path, with: .color(style.strokeColor), lineWidth: style.strokeWidth)
        }
    }
}
