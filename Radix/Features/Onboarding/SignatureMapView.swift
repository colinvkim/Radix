import SwiftUI

struct SignatureMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    let animates: Bool
    let replay: Int
    let showsCenterIcon: Bool

    var body: some View {
        let sectors = sectors
        ZStack {
            ForEach(0..<3) { ring in
                ZStack {
                    ForEach(Array(sectors.enumerated()), id: \.offset) { _, sector in
                        if sector.ring == ring {
                            MapSector(
                                start: sector.start,
                                end: sector.end,
                                inner: sector.inner,
                                outer: sector.outer
                            )
                            .fill(sector.color.opacity(sector.opacity))
                        }
                    }
                }
                .scaleEffect(appeared ? 1 : 0.68)
                .rotationEffect(.degrees(appeared ? 0 : -18))
                .opacity(appeared ? 1 : 0)
                .animation(
                    animates && !reduceMotion
                        ? .easeOut(duration: 0.7).delay(Double(ring) * 0.1)
                        : nil,
                    value: appeared
                )
            }

            if showsCenterIcon {
                Image(systemName: "scope")
                    .font(.system(size: 25, weight: .ultraLight))
                    .foregroundStyle(Color(red: 0.38, green: 0.58, blue: 0.82))
            }
        }
        .frame(width: 246, height: 246)
        .accessibilityHidden(true)
        .task(id: replay) {
            guard animates && !reduceMotion else {
                appeared = true
                return
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { appeared = false }
            // Separate the starting and final states so replay has a visible entrance.
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            appeared = true
        }
    }

    private var sectors: [Sector] {
        let colors = [
            Color(red: 0.33, green: 0.69, blue: 0.73),
            Color(red: 0.36, green: 0.55, blue: 0.83),
            Color(red: 0.56, green: 0.47, blue: 0.83)
        ]
        let spans = [153.0, 122, 85]
        let subdivisions = [[0.48, 0.27, 0.25], [0.24, 0.45, 0.31], [0.61, 0.39]]
        var result: [Sector] = []
        var start = -120.0

        for branch in 0..<3 {
            let end = start + spans[branch]
            result.append(Sector(ring: 0, start: start + 0.8, end: end - 0.8, inner: 0.34, outer: 0.51, color: colors[branch], opacity: 1))
            var childStart = start
            for (index, fraction) in subdivisions[branch].enumerated() {
                let childEnd = childStart + spans[branch] * fraction
                result.append(Sector(ring: 1, start: childStart + 0.8, end: childEnd - 0.8, inner: 0.53, outer: 0.7, color: colors[branch], opacity: 0.78 + Double(index) * 0.08))
                if index != 1 || branch == 0 {
                    let middle = childStart + (childEnd - childStart) * 0.58
                    result.append(Sector(ring: 2, start: childStart + 0.8, end: middle - 0.8, inner: 0.72, outer: 0.86, color: colors[branch], opacity: 0.55))
                    result.append(Sector(ring: 2, start: middle + 0.8, end: childEnd - 0.8, inner: 0.72, outer: index == 0 ? 0.95 : 0.86, color: colors[branch], opacity: 0.75))
                }
                childStart = childEnd
            }
            start = end
        }
        return result
    }

    private struct Sector {
        let ring: Int
        let start: Double
        let end: Double
        let inner: Double
        let outer: Double
        let color: Color
        let opacity: Double
    }
}

private struct MapSector: Shape {
    let start: Double
    let end: Double
    let inner: Double
    let outer: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.addArc(center: center, radius: radius * outer, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        path.addArc(center: center, radius: radius * inner, startAngle: .degrees(end), endAngle: .degrees(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}
