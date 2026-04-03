import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Radix", systemImage: "scope")
                    .font(.largeTitle.weight(.bold))

                Text("Scan disks and folders with a native macOS workflow, inspect results when the scan completes, and stay read-only until you explicitly choose a file action.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 20) {
                GroupBox("How Radix Works") {
                    VStack(alignment: .leading, spacing: 16) {
                        featureRow(
                            systemImage: "lock.shield",
                            title: "Read-only by default",
                            body: "Radix scans and summarizes usage. It only asks macOS to move an item to the Trash when you explicitly choose that action."
                        )
                        featureRow(
                            systemImage: "folder.badge.gearshape",
                            title: "Built around Finder",
                            body: "Choose folders with the standard open panel, reveal results in Finder, and drag locations directly into the window."
                        )
                        featureRow(
                            systemImage: "hand.raised",
                            title: "Full Disk Access is optional",
                            body: "Grant it only if you want more complete results from protected locations such as Mail, Safari, Messages, and Library content."
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Before Your First Scan") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Normal folders can be scanned immediately. Protected system and privacy-sensitive locations require Full Disk Access in System Settings.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 10) {
                            onboardingStep(symbol: "1.circle.fill", text: "Open Full Disk Access Settings.")
                            onboardingStep(symbol: "2.circle.fill", text: "Find Radix in Privacy & Security > Full Disk Access.")
                            onboardingStep(symbol: "3.circle.fill", text: "Enable the toggle, then return to Radix.")
                        }

                        Text("You can scan without this permission and enable it later if a scan reports skipped folders.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 12) {
                Button("Choose Folder to Scan") {
                    appModel.dismissOnboarding()
                    appModel.presentOpenPanelAndScan()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button("Open Full Disk Access Settings") {
                    appModel.prepareAndOpenFullDiskAccessSettings()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Not Now") {
                    appModel.dismissOnboarding()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 820, alignment: .topLeading)
        .frame(minHeight: 500, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func featureRow(systemImage: String, title: String, body: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, alignment: .center)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func onboardingStep(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
        }
    }
}
