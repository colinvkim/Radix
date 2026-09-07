import SwiftUI

struct OnboardingFlowView: View {
    @Binding var step: OnboardingPage
    let status: FullDiskAccessStatus
    let openSettings: () -> Void
    let finish: (_ startsTour: Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(verbatim: "Radix").font(.headline)
                Spacer()
            }
            .font(.callout)
            .padding(20)

            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcome
                    case .access: access
                    case .tour: tourInvitation
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, step == .access ? 12 : 24)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            if step != .welcome {
                navigation
            }
        }
        .frame(width: 620, height: step == .access ? 360 : 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            SignatureMapView()
                .frame(height: 232)
            heading("Make space\nfor what matters.", description: "Explore your files visually, find the large ones, and decide what to keep.")
            primaryAction
        }
        .padding(.top, 8)
    }

    private var access: some View {
        VStack(spacing: 12) {
            featureIcon("lock.open")
            VStack(spacing: 8) {
                Text("Full Disk Access")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Let Radix scan protected folders for a more complete view of your disk.")
                    .foregroundStyle(.secondary)
            }

            if status == .granted {
                Label {
                    Text("Full Disk Access is enabled.")
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else {
                VStack(spacing: 6) {
                    Text("Enable Radix under Full Disk Access in System Settings.")
                        .font(.callout)
                    Text("Choose Quit & Reopen if prompted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if status == .unknown {
                        Text("Full Disk Access could not be verified.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tourInvitation: some View {
        VStack(spacing: 20) {
            featureIcon("macwindow")
            heading("Get to know your workspace.", description: "Explore Radix with sample files. Get to know the controls, then try the Discard Pile.")

            VStack(alignment: .leading, spacing: 14) {
                tourFeature("Explore your files in the disk map", symbol: "chart.pie")
                tourFeature("Learn what the workspace controls do", symbol: "slider.horizontal.3")
                tourFeature("Drag items into the Discard Pile and review them", symbol: "checklist")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            Text("You can take the tour later from Help.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var navigation: some View {
        HStack(spacing: 12) {
            Button {
                step = step == .tour ? .access : .welcome
            } label: { Text("Back") }
            Spacer(minLength: 8)
            if step == .access && status != .granted {
                Button { step = .tour } label: { Text("Skip for Now") }
            } else if step == .tour {
                Button { finish(false) } label: { Text("Skip") }
            }
            primaryAction
        }
        .controlSize(.large)
        .padding(20)
    }

    private var primaryAction: some View {
        Button(action: advance) {
            Text(primaryTitle)
                .frame(minWidth: step == .welcome ? 126 : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: "Get Started"
        case .access: status == .granted ? "Continue" : "Open System Settings"
        case .tour: "Start Quick Tour"
        }
    }

    private func advance() {
        switch step {
        case .welcome: step = .access
        case .access:
            if status == .granted { step = .tour } else { openSettings() }
        case .tour: finish(true)
        }
    }

    private func featureIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 44, weight: .light))
            .foregroundStyle(Color.accentColor)
            .accessibilityHidden(true)
            .padding(.top, 8)
    }

    private func tourFeature(_ title: LocalizedStringKey, symbol: String) -> some View {
        Label {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
        }
    }

    private func heading(_ title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(description).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}
