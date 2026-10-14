import SwiftUI

nonisolated enum TreemapColorAppearance: Equatable, Sendable {
    case light
    case dark
}

nonisolated struct TreemapColorComponents: Equatable, Hashable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    nonisolated var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

/// Treemaps devote much more area to color than the sunburst, so they use a
/// calmer, appearance-aware palette with stronger variation between siblings.
nonisolated enum TreemapColorResolver {
    private nonisolated static let branchHues: [Double] = [
        0.58, // blue
        0.08, // orange
        0.38, // green
        0.76, // purple
        0.49, // teal
        0.94, // pink
        0.14, // yellow
        0.66  // indigo
    ]
    nonisolated static func color(
        for token: SunburstColorToken,
        appearance: TreemapColorAppearance
    ) -> Color {
        components(for: token, appearance: appearance).color
    }

    nonisolated static func components(
        for token: SunburstColorToken,
        appearance: TreemapColorAppearance
    ) -> TreemapColorComponents {
        switch token.role {
        case .aggregate:
            return neutralComponents(brightness: appearance == .dark ? 0.36 : 0.82)
        case .freeSpace:
            return neutralComponents(brightness: appearance == .dark ? 0.42 : 0.76)
        case .normal:
            break
        }

        let baseHue = branchHues[token.branchIndex % branchHues.count]
        let localUnit = DiskMapColorMath.stableUnitInterval(for: token.localID)
        let localVariant = DiskMapColorMath.centered(localUnit)
        let isBranchRoot = token.branchID == token.localID
        let siblingPosition = token.siblingCount > 1
            ? Double(token.siblingIndex) / Double(token.siblingCount - 1)
            : 0.5
        let siblingVariant = DiskMapColorMath.centered(siblingPosition)
        let hue = DiskMapColorMath.normalizedHue(
            baseHue
                + (isBranchRoot ? 0 : localVariant * 0.20)
                + (siblingVariant * 0.045)
        )
        let depth = min(Double(token.depth), 7)
        let brightnessVariant = variantBrightnessOffset(for: token.localID)

        switch appearance {
        case .dark:
            return TreemapColorComponents(
                hue: hue,
                saturation: DiskMapColorMath.clamped(
                    0.58 + (localVariant * 0.08) - (depth * 0.012),
                    lower: 0.44,
                    upper: 0.66
                ),
                brightness: DiskMapColorMath.clamped(
                    0.64 - (depth * 0.024) + (brightnessVariant * 0.025),
                    lower: 0.46,
                    upper: 0.68
                )
            )
        case .light:
            return TreemapColorComponents(
                hue: hue,
                saturation: DiskMapColorMath.clamped(
                    0.48 + (localVariant * 0.07) - (depth * 0.01),
                    lower: 0.36,
                    upper: 0.56
                ),
                brightness: DiskMapColorMath.clamped(
                    0.9 - (depth * 0.022) + (brightnessVariant * 0.018),
                    lower: 0.73,
                    upper: 0.93
                )
            )
        }
    }

    private nonisolated static func neutralComponents(brightness: Double) -> TreemapColorComponents {
        TreemapColorComponents(hue: 0, saturation: 0, brightness: brightness)
    }

    private nonisolated static func variantBrightnessOffset(for key: String) -> Double {
        switch DiskMapColorMath.stableHash(for: key) % 5 {
        case 0:
            return -1
        case 1:
            return -0.5
        case 2:
            return 0
        case 3:
            return 0.5
        default:
            return 1
        }
    }

}
