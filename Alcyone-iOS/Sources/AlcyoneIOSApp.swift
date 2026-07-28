import Alcyone
import SwiftUI

/// iPad shell around the shared DashboardView. Drives Electra until the BLE
/// dongle (phase 1) swaps in a real TelemetrySource.
@main
struct AlcyoneIOSApp: App {
    private let source: ElectraSource
    @StateObject private var model: TelemetryModel

    init() {
        let source = ElectraSource()
        self.source = source
        _model = StateObject(wrappedValue: TelemetryModel(source: source))
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(model: model, bench: source)
                .onAppear { model.start() }
        }
    }
}
