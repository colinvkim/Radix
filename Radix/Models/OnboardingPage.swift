import Foundation

nonisolated enum OnboardingPage: String, CaseIterable, Identifiable, Sendable {
    case welcome, access, tour

    var id: Self { self }
}
