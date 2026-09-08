//
//  RadixApp.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import AppKit
import Sparkle
import SwiftUI

@main
struct RadixApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var softwareUpdates: SoftwareUpdateModel
    private let updaterController: SPUStandardUpdaterController
    private let issueReportURL = URL(string: "https://github.com/colinvkim/Radix/issues/new/choose")

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updaterController
        _softwareUpdates = StateObject(wrappedValue: SoftwareUpdateModel(updater: updaterController.updater))
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
                navigation: appModel.navigation,
                workspaceTour: appModel.workspaceTour
            )

            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(softwareUpdates: softwareUpdates)
            }

            CommandGroup(after: .help) {
                Button("Report Issue…", systemImage: "flag") {
                    if let issueReportURL {
                        NSWorkspace.shared.open(issueReportURL)
                    }
                }
            }
        }

        Settings {
            SettingsView(softwareUpdates: softwareUpdates)
                .environmentObject(appModel)
        }
    }
}
