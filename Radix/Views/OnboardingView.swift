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

            VStack(alignment: .leading, spacing: 14) {
                Text("Full Disk Access Setup")
                    .font(.headline)

                Text("Radix can scan selected folders without this, but protected locations such as Mail, Messages, Safari, and some Library content remain incomplete until you enable Full Disk Access.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    onboardingStep(number: 1, text: "Click Open Full Disk Access Settings.")
                    onboardingStep(number: 2, text: "In Privacy & Security > Full Disk Access, find Radix in the list.")
                    onboardingStep(number: 3, text: "Turn on the toggle for Radix, then return here and continue.")
                }

                Text("macOS does not let apps enable this permission themselves. Radix can only open the right settings pane and try to get itself listed first.")
                    .font(.callout)
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

                Button("Open Full Disk Access Settings") {
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

    private func onboardingStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.thinMaterial, in: Circle())

            Text(text)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
    }
}
