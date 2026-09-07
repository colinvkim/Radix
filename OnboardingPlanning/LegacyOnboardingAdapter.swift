import Combine
import SwiftUI

// This target keeps Radix's original onboarding as a frozen comparison. Its
// small adapter provides preview state in place of the real application model.
// No production services, preferences, or system actions are linked here.
@MainActor
final class AppModel: ObservableObject {
    @Published var fullDiskAccessStatus: FullDiskAccessStatus = .notGranted
    @Published var didDismissOnboarding = false
    @Published var showsAccessSimulation = false

    func dismissOnboarding() {
        didDismissOnboarding = true
    }

    func prepareAndOpenFullDiskAccessSettingsFromOnboarding() {
        showsAccessSimulation = true
    }

    func refreshFullDiskAccessStatus() {
        // The preview controls supply this status; never probe the user's disk.
    }
}

enum FullDiskAccessStatus: CaseIterable, Identifiable {
    case notGranted, granted, unknown

    var id: Self { self }

    var fullDiskAccessBadgeTitle: String {
        switch self {
        case .granted: String(localized: "Enabled")
        case .notGranted: String(localized: "Not Enabled")
        case .unknown: String(localized: "Unknown")
        }
    }

    var fullDiskAccessSystemImage: String {
        switch self {
        case .granted: "checkmark.circle.fill"
        case .notGranted: "xmark.circle.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var fullDiskAccessColor: Color {
        switch self {
        case .granted: .green
        case .notGranted: .orange
        case .unknown: .secondary
        }
    }
}
