//
//  OnboardingView.swift
//  Radix
//
//  Created by Codex on 4/2/26.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Welcome to Radix", systemImage: "sun.max")
                    .font(.largeTitle.weight(.bold))

                Text("Scan disks and folders with a live sunburst map, inspect what is actually consuming space, and stay in a safe read-only workflow.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                onboardingCard(
                    title: "Read-only by design",
                    body: "Radix does not delete or move anything in v1. It scans, summarizes, and helps you inspect results."
                )
                onboardingCard(
                    title: "Native macOS workflow",
                    body: "Choose targets with the standard open panel, drag folders into the window, and reveal items directly in Finder."
                )
                onboardingCard(
                    title: "Optional Full Disk Access",
                    body: "Granting Full Disk Access improves scan completeness on protected folders such as Mail, Safari, and other privacy-sensitive locations."
                )
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Full Disk Access Setup")
                    .font(.headline)

                Text("Radix can open the correct Privacy & Security pane and try to get itself listed first. macOS still requires the user to enable the toggle manually.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 12) {
                Button("Choose Folder to Scan") {
                    appModel.dismissOnboarding()
                    appModel.presentOpenPanelAndScan()
                }
                .buttonStyle(.borderedProminent)

                Button("Set Up Full Disk Access") {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Continue") {
                    appModel.dismissOnboarding()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func onboardingCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
