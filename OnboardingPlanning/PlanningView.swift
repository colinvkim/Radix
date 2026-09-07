import SwiftUI

private enum PreviewMode: String, CaseIterable, Identifiable {
    case current, proposed, guided, compare

    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .proposed: "Proposed"
        case .current: "Current"
        case .guided: "Version 3"
        case .compare: "Compare"
        }
    }
    var symbol: String {
        switch self {
        case .proposed: "sparkles"
        case .current: "clock"
        case .guided: "cursorarrow.click"
        case .compare: "rectangle.split.2x1"
        }
    }
}

private enum PreviewAppearance: CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private enum PreviewOutcome {
    case scan, workspace, workspaceTour

    var message: LocalizedStringKey {
        switch self {
        case .scan: "Preview complete. In Radix, your scan would begin here."
        case .workspace: "Preview complete. Radix would open its workspace without the tour."
        case .workspaceTour: "Preview complete. The tour would begin in Radix’s workspace."
        }
    }
}

struct PlanningView: View {
    var quickTourRequest: Int

    @StateObject private var legacy = AppModel()
    @State private var mode: PreviewMode = .guided
    @State private var comparison: PreviewMode = .proposed
    @State private var guidedStep: OnboardingPage = .welcome
    @State private var step: OnboardingStep = .welcome
    @State private var appearance: PreviewAppearance = .system
    @State private var animates = true
    @State private var replay = 0
    @State private var presentedDesign: PreviewMode?
    @State private var outcome: PreviewOutcome?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 195, max: 220)
        } detail: {
            VStack(spacing: 0) {
                controls
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if mode == .compare {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 20) {
                                    comparisonPreview
                                    guidedPreview()
                                }
                                VStack(spacing: 32) {
                                    comparisonPreview
                                    guidedPreview()
                                }
                            }
                        } else if mode == .current {
                            currentPreview
                        } else if mode == .proposed {
                            proposedPreview
                        } else {
                            guidedPreview(showsCaption: false)
                        }
                    }
                    .padding(mode == .guided || mode == .compare ? 16 : 30)
                    .frame(maxWidth: .infinity)
                }
                .background {
                    Color(nsColor: .windowBackgroundColor)
                        .overlay(.primary.opacity(0.035))
                }
                Divider()
                footer
            }
            .navigationTitle(Text("Onboarding Planning", tableName: "Planning"))
            .toolbar {
                ToolbarItemGroup {
                    Button(action: restart) {
                        Label {
                            Text("Replay", tableName: "Planning")
                        } icon: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                    }
                    .keyboardShortcut("r")

                    Button {
                        presentedDesign = mode == .compare ? .guided : mode
                    } label: {
                        Label {
                            Text(presentationTitle, tableName: "Planning")
                        } icon: {
                            Image(systemName: "play.rectangle")
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .preferredColorScheme(appearance.colorScheme)
        .sheet(item: $presentedDesign) { design in
            Group {
                if design == .current {
                    currentContent
                } else if design == .proposed {
                    proposedContent(usesDefaultAction: true)
                } else {
                    guidedContent(usesDefaultAction: true)
                }
            }
            .sheet(isPresented: $legacy.showsAccessSimulation) { accessSimulation }
        }
        .sheet(isPresented: Binding(
            get: { presentedDesign == nil && legacy.showsAccessSimulation },
            set: { legacy.showsAccessSimulation = $0 }
        )) {
            accessSimulation
        }
        .onChange(of: step) { _, _ in outcome = nil }
        .onChange(of: mode) { _, _ in outcome = nil }
        .onChange(of: guidedStep) { _, _ in outcome = nil }
        .onChange(of: quickTourRequest) { _, _ in
            mode = .guided
            presentedDesign = nil
            guidedStep = .tour
            outcome = nil
        }
        .onChange(of: legacy.didDismissOnboarding) { _, dismissed in
            if dismissed && presentedDesign == .current {
                presentedDesign = nil
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Radix")
                        .font(.headline)
                    Text("Onboarding study", tableName: "Planning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)

            List(selection: Binding<PreviewMode?>(
                get: { mode }, set: { if let value = $0 { mode = value } }
            )) {
                Section {
                    ForEach(PreviewMode.allCases) { item in
                        Label {
                            Text(item.title, tableName: "Planning")
                        } icon: {
                            Image(systemName: item.symbol)
                        }
                        .padding(.vertical, 5)
                        .tag(item)
                    }
                } header: {
                    Text("Designs", tableName: "Planning")
                }

            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            Text("Three approaches to getting started.", tableName: "Planning")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(20)
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            scenarioControls
            if mode != .current {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 24) {
                        screenControls
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 10) { screenControls }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 24)
        .padding(.vertical, 15)
    }

    @ViewBuilder
    private var screenControls: some View {
        if mode == .compare {
            Picker(selection: $comparison) {
                Text("Current", tableName: "Planning").tag(PreviewMode.current)
                Text("Proposed", tableName: "Planning").tag(PreviewMode.proposed)
            } label: { Text("Compare with", tableName: "Planning") }
            .frame(width: 240)
        }
        if mode == .proposed || (mode == .compare && comparison == .proposed) {
            Picker(selection: $step) {
                ForEach(OnboardingStep.allCases) { item in
                    Text(item.title, tableName: "Planning").tag(item)
                }
            } label: { Text("Proposed", tableName: "Planning") }
            .frame(width: 220)
        }
        if mode == .guided || mode == .compare {
            Picker(selection: $guidedStep) {
                ForEach(OnboardingPage.allCases) { item in
                    Text(item.title, tableName: "Planning").tag(item)
                }
            } label: { Text("Version 3", tableName: "Planning") }
            .frame(width: 270)
        }
    }

    private var scenarioControls: some View {
        HStack(spacing: 24) {
            Picker(selection: $legacy.fullDiskAccessStatus) {
                ForEach(FullDiskAccessStatus.allCases) { status in
                    Text(status.fullDiskAccessBadgeTitle).tag(status)
                }
            } label: {
                Text("Disk Access", tableName: "Planning")
            }
            .frame(width: 220)

            Picker(selection: $appearance) {
                ForEach(PreviewAppearance.allCases) { item in
                    Text(item.title, tableName: "Planning").tag(item)
                }
            } label: {
                Text("Appearance", tableName: "Planning")
            }
            .frame(width: 185)

            Toggle(isOn: $animates) {
                Text("Animate entrance", tableName: "Planning")
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
        }
    }

    private var presentationTitle: LocalizedStringKey {
        switch mode {
        case .current: "Present Current"
        case .proposed: "Present Proposed"
        default: "Present Version 3"
        }
    }

    @ViewBuilder
    private var comparisonPreview: some View {
        if comparison == .current { currentPreview } else { proposedPreview }
    }

    private var currentPreview: some View {
        preview(title: "Current", subtitle: "The welcome in Radix today.") {
            currentContent
        }
    }

    private var proposedPreview: some View {
        preview(title: "Proposed", subtitle: "Signature map · A warmer first hello.") {
            proposedContent()
        }
    }

    private func guidedPreview(showsCaption: Bool = true) -> some View {
        preview(title: "Version 3", subtitle: "Welcome, disk access, then a tour in the workspace.", width: 620, showsCaption: showsCaption) {
            guidedContent()
        }
    }

    private func preview<Content: View>(title: LocalizedStringKey, subtitle: LocalizedStringKey, width: CGFloat = 540, showsCaption: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsCaption {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title, tableName: "Planning")
                        .font(.title2.weight(.semibold))
                    Text(subtitle, tableName: "Planning")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            content()
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.07), radius: 16, y: 7)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private var currentContent: some View {
        if legacy.didDismissOnboarding {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Current onboarding completed.", tableName: "Planning")
                    .font(.title3)
                Button {
                    legacy.didDismissOnboarding = false
                } label: {
                    Text("Show Current Again", tableName: "Planning")
                }
            }
            .frame(width: 540, height: 590)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            LegacyOnboardingView()
                .environmentObject(legacy)
        }
    }

    private func proposedContent(usesDefaultAction: Bool = false) -> some View {
        ProposedOnboardingView(
            step: $step,
            status: legacy.fullDiskAccessStatus,
            animates: animates,
            replay: replay,
            usesDefaultAction: usesDefaultAction,
            openSettings: { legacy.showsAccessSimulation = true },
            finish: {
                outcome = .scan
                presentedDesign = nil
            }
        )
    }

    private func guidedContent(usesDefaultAction: Bool = false) -> some View {
        Group {
            if outcome == .workspace || outcome == .workspaceTour {
                WorkspaceTourPlanView(
                    startsTour: outcome == .workspaceTour,
                    usesDefaultAction: usesDefaultAction,
                    returnToChoice: { outcome = nil }
                )
            } else {
                OnboardingFlowView(
                    step: $guidedStep,
                    status: legacy.fullDiskAccessStatus,
                    animates: animates,
                    replay: replay,
                    usesDefaultAction: usesDefaultAction,
                    openSettings: { legacy.showsAccessSimulation = true },
                    finish: { startsTour in
                        outcome = startsTour ? .workspaceTour : .workspace
                        presentedDesign = nil
                    }
                )
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: outcome != nil ? "checkmark.circle" : "eye")
                .foregroundStyle(outcome != nil ? Color.accentColor : .secondary)
            Text(
                outcome?.message ?? "Preview only. No scans or permission changes.",
                tableName: "Planning"
            )
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 13)
    }

    private var accessSimulation: some View {
        AccessSimulationView(status: $legacy.fullDiskAccessStatus)
    }

    private func restart() {
        step = .welcome
        guidedStep = .welcome
        legacy.didDismissOnboarding = false
        outcome = nil
        replay += 1
    }
}

private struct AccessSimulationView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var status: FullDiskAccessStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Simulate Full Disk Access", tableName: "Planning")
                .font(.title2.weight(.semibold))
            Text("In Radix, this action opens System Settings. Here, choose the state you want to preview when you return.", tableName: "Planning")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker(selection: $status) {
                ForEach(FullDiskAccessStatus.allCases) { item in
                    Text(item.fullDiskAccessBadgeTitle).tag(item)
                }
            } label: {
                Text("Preview access", tableName: "Planning")
            }
            Divider()
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Text("Return to Preview", tableName: "Planning")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

private extension OnboardingPage {
    var title: LocalizedStringKey {
        switch self {
        case .welcome: "Welcome"
        case .access: "Disk Access"
        case .tour: "Quick Tour"
        }
    }
}
