//
//  SettingsView.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Show hidden files while scanning", isOn: $appModel.showHiddenFiles)
                Toggle("Treat app bundles and packages as folders", isOn: $appModel.treatPackagesAsDirectories)

                Text("Mounted volume scans always include hidden files automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Visualization") {
                Stepper(value: $appModel.maxRenderedDepth, in: 3...10) {
                    LabeledContent("Sunburst depth") {
                        Text("\(appModel.maxRenderedDepth) rings")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 460)
    }
}
