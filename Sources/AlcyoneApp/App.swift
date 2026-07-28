#if os(macOS)
import Alcyone
import AppKit
import SwiftUI

/// macOS bench runner: the Alcyone dashboard against the Electra fake car.
/// Run with `swift run alcyone`; the iPad shell wraps the same DashboardView.
@main
struct AlcyoneApp: App {
    private let source: ElectraSource
    @StateObject private var model: TelemetryModel

    init() {
        let source = ElectraSource()
        self.source = source
        _model = StateObject(wrappedValue: TelemetryModel(source: source))
    }

    var body: some Scene {
        WindowGroup("Alcyone ✦ Electra bench") {
            RootView(model: model, bench: source)
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
