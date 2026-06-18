//
//  RadixApp.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import AppKit
import Combine
import Sparkle
import SwiftUI

// This view model class publishes when new updates can be checked by the user
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }
}

// This is the view for the Check for Updates menu item
// Note this intermediate view is necessary for the disabled state on the menu item to work properly before Monterey.
// See https://stackoverflow.com/questions/68553092/menu-not-updating-swiftui-bug for more info
struct CheckForUpdatesView: View {
    @StateObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        
        // Create our view model for our CheckForUpdatesView
        _checkForUpdatesViewModel = StateObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
    }
    
    var body: some View {
        Button("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
            updater.checkForUpdates()
        }
            .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
    }
}

@main
struct RadixApp: App {
    @StateObject private var appModel = AppModel()
    private let updaterController: SPUStandardUpdaterController

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        Window("Radix", id: "main") {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1180, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        }
        .defaultSize(width: 1480, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            RadixCommands(
                appModel: appModel,
                scanState: appModel.scanState,
                navigation: appModel.navigation
            )

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
