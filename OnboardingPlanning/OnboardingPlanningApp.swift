import SwiftUI

@main
struct OnboardingPlanningApp: App {
    @State private var quickTourRequest = 0

    var body: some Scene {
        Window(String(localized: "Radix Onboarding", table: "Planning"), id: "planning") {
            PlanningView(quickTourRequest: quickTourRequest)
                .frame(minWidth: 980, minHeight: 740)
        }
        .defaultSize(width: 1480, height: 900)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button { quickTourRequest += 1 } label: {
                    Text("Take a Quick Tour", tableName: "Planning")
                }
            }
        }
    }
}
