import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                intro
                DiskMapTip()
                Divider()
                FullDiskAccessSetupCard(
                    status: appModel.fullDiskAccessStatus,
                    openSettings: {
                        appModel.prepareAndOpenFullDiskAccessSettingsFromOnboarding()
                    },
                    refreshStatus: {
                        appModel.refreshFullDiskAccessStatus()
                    }
                )
            }
            .padding(.horizontal, 38)
            .padding(.top, 34)
            .padding(.bottom, 30)

            Divider()

            HStack(spacing: 12) {
                Spacer()

                Button {
                    appModel.dismissOnboarding()
                } label: {
                    Text("Continue")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 16)
        }
        .frame(width: 540, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(ModalTerminationBehavior())
        .onAppear {
            appModel.refreshFullDiskAccessStatus()
        }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 62, height: 62)
                .accessibilityHidden(true)

            Text("Welcome to Radix")
                .font(.title2.weight(.semibold))

            Text("Scan folders and disks to see where space is going. Radix stays read-only until you choose a file action.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 390)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DiskMapTip: View {
    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Explore the disk map")
                    .font(.headline)
                Text("Hover over segments to inspect them. Double-click a folder segment or table row to drill down.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "chart.pie.fill")
                .foregroundStyle(Color.accentColor)
        }
    }
}

private struct FullDiskAccessSetupCard: View {
    let status: FullDiskAccessStatus
    let openSettings: () -> Void
    let refreshStatus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Full Disk Access")
                    .font(.headline)

                Spacer()

                FullDiskAccessStatusBadge(status: status)
            }

            Text(statusMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("To enable it:")
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                Text("1. Open Privacy & Security > Full Disk Access.")
                Text("2. Turn on Radix.")
                Text("3. Choose Quit & Reopen when macOS asks.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Open Full Disk Access") {
                    openSettings()
                }

                Button("Recheck") {
                    refreshStatus()
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var statusMessage: String {
        switch status {
        case .granted:
            return "Radix can currently read protected locations. You can start a complete scan now."
        case .notGranted:
            return "Radix does not currently have Full Disk Access. Normal scans still work; protected folders may be skipped."
        case .unknown:
            return "Radix could not verify Full Disk Access on this Mac. You can still scan ordinary folders."
        }
    }

}

private struct FullDiskAccessStatusBadge: View {
    let status: FullDiskAccessStatus

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(foregroundStyle)
            .accessibilityLabel("Full Disk Access \(title)")
    }

    private var title: String {
        switch status {
        case .granted:
            return "Enabled"
        case .notGranted:
            return "Not Enabled"
        case .unknown:
            return "Unknown"
        }
    }

    private var systemImage: String {
        switch status {
        case .granted:
            return "checkmark.circle.fill"
        case .notGranted:
            return "xmark.circle.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .granted:
            return .green
        case .notGranted:
            return .orange
        case .unknown:
            return .secondary
        }
    }

}

private struct ModalTerminationBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        updateWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        updateWindow(for: nsView)
    }

    private func updateWindow(for view: NSView) {
        DispatchQueue.main.async {
            view.window?.preventsApplicationTerminationWhenModal = false
        }
    }
}
