import SwiftUI

struct ShimmeringTextHighlight: View {
    let text: String
    var lineLimit = 1
    var reservesSpace = false
    var multilineTextAlignment: TextAlignment = .leading
    var truncationMode: Text.TruncationMode = .tail

    private let cycleDuration = 1.7

    var body: some View {
        TimelineView(.animation) { timeline in
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)
                let highlightWidth = min(max(width * 0.42, 48), 160)
                let progress = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
                let offset = progress * (width + highlightWidth * 2) - highlightWidth

                Text(text)
                    .foregroundStyle(Color.primary.opacity(0.68))
                    .multilineTextAlignment(multilineTextAlignment)
                    .lineLimit(lineLimit, reservesSpace: reservesSpace)
                    .truncationMode(truncationMode)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.2), location: 0.28),
                                .init(color: .white, location: 0.5),
                                .init(color: .white.opacity(0.2), location: 0.72),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: highlightWidth, height: height)
                        .offset(x: offset)
                        .frame(width: width, height: height, alignment: .leading)
                    }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
