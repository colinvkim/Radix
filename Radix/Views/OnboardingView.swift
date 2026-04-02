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
        HSplitView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Radix", systemImage: "scope")
                    .font(.largeTitle.weight(.bold))

                Text("Scan disks and folders with a native macOS workflow, inspect the live map as results stream in, and stay entirely read-only.")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    featureRow(
                        title: "Read-only by design",
                        body: "Radix scans and summarizes usage. It does not move or delete files."
                    )
                    featureRow(
                        title: "Works with Finder",
                        body: "Choose folders with the standard open panel, reveal results in Finder, and drag locations straight into the window."
                    )
                    featureRow(
                        title: "Full Disk Access is optional",
                        body: "Grant it only if you want more complete results from protected locations such as Mail, Safari, and Library content."
                    )
                }

                Spacer()
            }
            .padding(28)
            .frame(minWidth: 320, maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 18) {
                Text("Before your first scan")
                    .font(.title3.weight(.semibold))

                Text("Radix can scan normal folders immediately. For protected system and privacy-sensitive locations, enable Full Disk Access in System Settings.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    onboardingStep(number: 1, text: "Open Full Disk Access Settings.")
                    onboardingStep(number: 2, text: "Find Radix in Privacy & Security > Full Disk Access.")
                    onboardingStep(number: 3, text: "Enable the toggle, then return to Radix.")
                }

                Text("macOS controls this permission. Radix can only open the correct settings screen for you.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Spacer()

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
            .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private func featureRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
