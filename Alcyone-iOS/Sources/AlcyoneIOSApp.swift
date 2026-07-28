import Alcyone
import Sterope
import SwiftUI

/// iPad shell around the shared DashboardView. Drives Electra until the BLE
/// dongle (phase 1) swaps in a real TelemetrySource.
@main
struct AlcyoneIOSApp: App {
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
        WindowGroup {
            RootView(model: model, bench: source, ruleStore: ruleStore)
                .onAppear { model.start() }
        }
    }
}
