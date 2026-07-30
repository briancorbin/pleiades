#if os(macOS)
import Alcyone
import AppKit
import Sterope
import SwiftUI

/// macOS bench runner. Run with `swift run alcyone`. Source selection is
/// wired but Electra-only on macOS (the dongle needs the iOS shell's
/// Bluetooth permission plumbing).
@main
struct AlcyoneApp: App {
    private let ruleStore = RuleStore()
    private let chimeStore = ChimePolicyStore()
    @AppStorage("alcyone.source") private var sourceSelection = TelemetrySourceKind.electra.rawValue

    var body: some Scene {
        WindowGroup("Alcyone ✦ Electra bench") {
            SourceHostView(
                kind: TelemetrySourceKind(rawValue: sourceSelection) ?? .electra,
                selection: $sourceSelection,
                ruleStore: ruleStore,
                chimeStore: chimeStore
            )
            .id(sourceSelection)  // selection change → fresh source + model
            .frame(minWidth: 860, minHeight: 720)
            .onAppear {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}
#else
@main
struct AlcyoneApp {
    static func main() {
        print("The alcyone bench runner is macOS-only; the iPad shell lives in Alcyone-iOS/.")
    }
}
#endif
