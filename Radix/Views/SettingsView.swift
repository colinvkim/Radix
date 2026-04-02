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
            Toggle("Show hidden files while scanning", isOn: $appModel.showHiddenFiles)
            Text("Mounted volume scans always include hidden files automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Treat app bundles and packages as folders", isOn: $appModel.treatPackagesAsDirectories)

            VStack(alignment: .leading, spacing: 8) {
                Text("Sunburst depth")
                Stepper(value: $appModel.maxRenderedDepth, in: 3...10) {
                    Text("\(appModel.maxRenderedDepth) rings")
                }
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
