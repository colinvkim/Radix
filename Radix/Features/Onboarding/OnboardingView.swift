import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        OnboardingFlowView(
            step: $appModel.onboardingPage,
            status: appModel.fullDiskAccessStatus,
            animates: true,
            replay: 0,
            usesDefaultAction: true,
            openSettings: { appModel.prepareAndOpenFullDiskAccessSettingsFromOnboarding() },
            finish: { startsTour in appModel.completeOnboarding(startsTour: startsTour) }
        )
        .background(ModalTerminationBehavior())
        .onAppear { appModel.refreshFullDiskAccessStatus() }
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
