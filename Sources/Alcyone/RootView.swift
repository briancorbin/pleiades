import SwiftUI

/// Alcyone's top level: Dashboard and Diagnostics tabs. The diagnostics tab
/// badges when codes are stored.
public struct RootView: View {
    @ObservedObject var model: TelemetryModel
    let bench: ElectraSource?

    public init(model: TelemetryModel, bench: ElectraSource? = nil) {
        self.model = model
        self.bench = bench
    }

    public var body: some View {
        TabView {
            DashboardView(model: model, bench: bench)
                .tabItem { Label("Dashboard", systemImage: "gauge.with.needle") }
            DiagnosticsView(model: model, bench: bench)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .badge(model.dtcs.count)
        }
        .background(Theme.background)
    }
}
