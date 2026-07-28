import Alcyone
import Sterope
import SwiftUI

/// iPad shell. The source badge in the dashboard header is a menu:
/// Electra (simulated) or the BLE dongle (real car, once it arrives).
@main
struct AlcyoneIOSApp: App {
    private let ruleStore = RuleStore()
    @AppStorage("alcyone.source") private var sourceSelection = TelemetrySourceKind.electra.rawValue

    var body: some Scene {
        WindowGroup {
            SourceHostView(
                kind: TelemetrySourceKind(rawValue: sourceSelection) ?? .electra,
                selection: $sourceSelection,
                ruleStore: ruleStore
            )
            .id(sourceSelection)  // selection change → fresh source + model
        }
    }
}
