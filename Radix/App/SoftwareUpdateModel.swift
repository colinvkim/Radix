import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class SoftwareUpdateModel: ObservableObject {
    @Published private(set) var canCheckForUpdates: Bool
    @Published private(set) var automaticallyChecksForUpdates: Bool
    @Published private(set) var lastUpdateCheckDate: Date?

    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate

        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .assign(to: &$lastUpdateCheckDate)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func restoreDefaultPreferences() {
        setAutomaticallyChecksForUpdates(
            Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool ?? false
        )
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject var softwareUpdates: SoftwareUpdateModel

    var body: some View {
        Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
            softwareUpdates.checkForUpdates()
        }
        .disabled(!softwareUpdates.canCheckForUpdates)
    }
}
