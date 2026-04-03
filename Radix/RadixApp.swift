//
//  RadixApp.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import AppKit
import SwiftUI

@main
struct RadixApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1180, maxWidth: .infinity, minHeight: 760, maxHeight: .infinity)
        }
        .defaultSize(width: 1480, height: 920)
        .windowResizability(.contentMinSize)
        .commands { RadixCommands(appModel: appModel) }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
