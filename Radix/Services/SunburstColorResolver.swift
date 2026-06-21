//
//  SunburstColorResolver.swift
//  Radix
//

import SwiftUI

nonisolated enum SunburstColorRole: Hashable, Sendable {
    case normal
    case aggregate
    case freeSpace
}

nonisolated struct SunburstColorToken: Hashable, Sendable {
    let role: SunburstColorRole
    let branchID: String
    let localID: String
    let branchIndex: Int
    let branchCount: Int
    let siblingIndex: Int
    let siblingCount: Int
    let depth: Int

    init(
        branchID: String,
        localID: String,
        branchIndex: Int,
        branchCount: Int,
        siblingIndex: Int,
        siblingCount: Int,
        depth: Int,
        role: SunburstColorRole
    ) {
        self.role = role
        self.branchID = branchID
        self.localID = localID
        self.branchIndex = max(branchIndex, 0)
        self.branchCount = max(branchCount, 1)
        self.siblingIndex = max(siblingIndex, 0)
        self.siblingCount = max(siblingCount, 1)
        self.depth = max(depth, 0)
    }

    static func single(
        id: String,
        depth: Int = 0,
        role: SunburstColorRole = .normal
    ) -> SunburstColorToken {
        SunburstColorToken(
            branchID: id,
            localID: id,
            branchIndex: 0,
            branchCount: 1,
            siblingIndex: 0,
            siblingCount: 1,
            depth: depth,
            role: role
        )
    }
}

nonisolated struct SunburstColorComponents: Equatable, Hashable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    nonisolated var color: Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}

nonisolated enum SunburstColorResolver {
    private nonisolated static let fnvPrime: UInt64 = 1_099_511_628_211
    private nonisolated static let fnvOffsetBasis: UInt64 = 14_695_981_039_346_656_037

    nonisolated static func color(for token: SunburstColorToken) -> Color {
        components(for: token).color
    }

    nonisolated static func components(for token: SunburstColorToken) -> SunburstColorComponents {
        switch token.role {
        case .aggregate:
            return SunburstColorComponents(hue: 0, saturation: 0, brightness: 0.55)
        case .freeSpace:
            return SunburstColorComponents(hue: 0, saturation: 0, brightness: 0.62)
        case .normal:
            break
        }

        let branchHue = stableUnitInterval(for: token.branchID)
        let localUnit = stableUnitInterval(for: token.localID)
        let localVariant = centered(localUnit)
        let depthTone = min(Double(token.depth), 6)
        let hue = normalizedHue(
            branchHue
                + (localVariant * 0.11)
                + (Double(token.depth % 2) * 0.015)
        )
        let saturation = clamped(
            0.74
                - (depthTone * 0.035)
                + (localVariant * 0.08),
            lower: 0.48,
            upper: 0.86
        )
        let brightness = clamped(
            0.84
                - (depthTone * 0.055)
                + (variantBrightnessOffset(for: token.localID) * 0.035),
            lower: 0.48,
            upper: 0.9
        )

        return SunburstColorComponents(
            hue: hue,
            saturation: saturation,
            brightness: brightness
        )
    }

    private nonisolated static func variantBrightnessOffset(for key: String) -> Double {
        switch stableHash(for: key) % 4 {
        case 0:
            return 0.5
        case 1:
            return -0.5
        case 2:
            return 1
        default:
            return -1
        }
    }

    private nonisolated static func stableUnitInterval(for key: String) -> Double {
        Double(stableHash(for: key)) / Double(UInt64.max)
    }

    private nonisolated static func stableHash(for key: String) -> UInt64 {
        var hash = fnvOffsetBasis
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        return hash
    }

    private nonisolated static func centered(_ value: Double) -> Double {
        value - 0.5
    }

    private nonisolated static func normalizedHue(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    private nonisolated static func clamped(
        _ value: Double,
        lower: Double,
        upper: Double
    ) -> Double {
        min(max(value, lower), upper)
    }
}
