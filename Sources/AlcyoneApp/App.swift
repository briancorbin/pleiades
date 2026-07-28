#if os(macOS)
import Alcyone
import AppKit
import Sterope
import SwiftUI

/// macOS bench runner: the Alcyone dashboard against the Electra fake car.
/// Run with `swift run alcyone`; the iPad shell wraps the same DashboardView.
@main
struct AlcyoneApp: App {
    private let source: ElectraSource
    private let ruleStore: RuleStore
    @StateObject private var model: TelemetryModel

    init() {
        let source = ElectraSource()
        let ruleStore = RuleStore()
        self.source = source
        self.ruleStore = ruleStore
        _model = StateObject(wrappedValue: TelemetryModel(source: source, ruleStore: ruleStore))
    }

    var body: some Scene {
        WindowGroup("Alcyone ✦ Electra bench") {
            RootView(model: model, bench: source, ruleStore: ruleStore)
                .frame(minWidth: 860, minHeight: 720)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    model.start()
                }
        }
    }
}
#else
@main
struct AlcyoneApp {
    static func main() {
        print("The alcyone bench runner is macOS-only; the iPad shell comes with phase 2 hardware.")
    }
}
#endif
