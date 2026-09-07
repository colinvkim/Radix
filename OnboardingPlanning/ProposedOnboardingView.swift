import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, access, firstScan

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome"
        case .access: "Disk Access"
        case .firstScan: "First Scan"
        }
    }

}

struct ProposedOnboardingView: View {
    @Binding var step: OnboardingStep

    let status: FullDiskAccessStatus
    let animates: Bool
    let replay: Int
    let usesDefaultAction: Bool
    let openSettings: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(verbatim: "Radix")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if step == .welcome {
                    Text("Welcome", tableName: "Planning")
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        step = step == .firstScan ? .access : .welcome
                    } label: {
                        Label {
                            Text("Back", tableName: "Planning")
                        } icon: {
                            Image(systemName: "chevron.left")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 26)
            .padding(.top, 22)

            Group {
                switch step {
                case .welcome: welcome
                case .access: diskAccess
                case .firstScan: firstScan
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 42)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, minHeight: 540)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            SignatureMapView(animates: animates, replay: replay, showsCenterIcon: true)
                .padding(.top, 6)

            Text("Make space\nfor what matters.", tableName: "Planning")
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.7)
                .padding(.top, 6)

            Text("See what’s taking up room on your Mac.\nExplore it. Decide what stays.", tableName: "Planning")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Button {
                step = .access
            } label: {
                Text("Get Started", tableName: "Planning")
                    .frame(minWidth: 126)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(usesDefaultAction ? .defaultAction : nil)
            .padding(.top, 26)

            reassurance
                .padding(.top, 16)
        }
    }

    private var diskAccess: some View {
        VStack(spacing: 0) {
            featureIcon(status == .granted ? "checkmark.shield" : "lock.open")
                .padding(.bottom, 26)

            Text(
                status == .granted ? "Ready for a closer look." : "See more of your disk.",
                tableName: "Planning"
            )
            .font(.system(size: 28, weight: .semibold))
            .tracking(-0.6)

            accessDescription
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            HStack(spacing: 13) {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Full Disk Access")
                        .font(.headline)
                    Text("Scanning doesn’t change your files.", tableName: "Planning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                accessBadge
            }
            .multilineTextAlignment(.leading)
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 28)

            Button {
                if status == .granted { step = .firstScan } else { openSettings() }
            } label: {
                Text(
                    status == .granted ? "Choose What to Scan" : "Set Up Full Disk Access",
                    tableName: "Planning"
                )
                .frame(minWidth: 170)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(usesDefaultAction ? .defaultAction : nil)
            .padding(.top, 28)

            if status != .granted {
                Button {
                    step = .firstScan
                } label: {
                    Text("Continue for Now", tableName: "Planning")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 18)
            }
        }
        .padding(.top, 26)
    }

    @ViewBuilder
    private var accessDescription: some View {
        switch status {
        case .granted:
            Text("Full Disk Access is enabled.\nChoose where you’d like to start.", tableName: "Planning")
        case .notGranted:
            Text("Full Disk Access lets Radix include more protected folders in your scan.", tableName: "Planning")
        case .unknown:
            Text("Radix couldn’t verify access. You can still scan an ordinary folder.", tableName: "Planning")
        }
    }

    @ViewBuilder
    private var accessBadge: some View {
        if status == .granted {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(Text("Enabled"))
        } else {
            Text(status == .unknown ? "Not verified" : "Optional", tableName: "Planning")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var firstScan: some View {
        VStack(spacing: 0) {
            featureIcon("folder")
                .padding(.bottom, 26)

            Text("Start somewhere familiar.", tableName: "Planning")
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.6)

            Text("Choose a folder or explore your disk.", tableName: "Planning")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 14)

            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "Macintosh HD")
                        .font(.headline)
                    Text("Your startup disk", tableName: "Planning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: finish) {
                    Text("Scan", tableName: "Planning")
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 30)

            Button(action: finish) {
                Text("Choose Folder…")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(usesDefaultAction ? .defaultAction : nil)
            .padding(.top, 22)

            reassurance
                .padding(.top, 18)
        }
        .padding(.top, 24)
    }

    private var reassurance: some View {
        Text("Scanning doesn’t change your files.", tableName: "Planning")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func featureIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 32, weight: .light))
            .foregroundStyle(Color.accentColor)
            .frame(width: 76, height: 76)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 21))
            .accessibilityHidden(true)
    }
}
