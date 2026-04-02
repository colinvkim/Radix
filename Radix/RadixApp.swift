//
//  RadixApp.swift
//  Radix
//
//  Created by Colin Kim on 4/1/26.
//

import SwiftUI

@main
struct RadixApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1180, maxWidth: .infinity, minHeight: 760, maxHeight: .infinity)
        }
        .defaultSize(width: 1480, height: 920)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(UnifiedWindowToolbarStyle(showsTitle: true))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scan Folder…") {
                    appModel.presentOpenPanelAndScan()
                }
                .keyboardShortcut("o")

                Button("Rescan") {
                    appModel.rescan()
                }
                .keyboardShortcut("r")
                .disabled(appModel.selectedTarget == nil)

                Button("Stop Scan") {
                    appModel.stopScan()
                }
                .keyboardShortcut(".")
                .disabled(!appModel.isScanning)
            }

            CommandMenu("Inspect") {
                Button("Zoom Into Selection") {
                    appModel.zoomIntoSelection()
                }
                .keyboardShortcut(.return)

                Button("Zoom Out") {
                    appModel.zoomOut()
                }
                .keyboardShortcut("[", modifiers: [.command, .option])

                Divider()

                Button("Reveal in Finder") {
                    appModel.revealSelectedInFinder()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Copy Path") {
                    appModel.copySelectedPath()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel)
        }
    }
}
