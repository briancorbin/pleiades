import Sterope
import SwiftUI

/// Alcyone's top level: Dashboard, Diagnostics, and Alerts tabs, with badges
/// for stored codes and live alerts.
public struct RootView: View {
    @ObservedObject var model: TelemetryModel
    let bench: ElectraSource?
    let ruleStore: RuleStore
    let sourceSelection: Binding<String>?

    public init(
        model: TelemetryModel,
        bench: ElectraSource? = nil,
        ruleStore: RuleStore,
        sourceSelection: Binding<String>? = nil
    ) {
        self.model = model
        self.bench = bench
        self.ruleStore = ruleStore
        self.sourceSelection = sourceSelection
    }

    public var body: some View {
        TabView {
            DashboardView(model: model, bench: bench, sourceSelection: sourceSelection)
                .tabItem { Label("Dashboard", systemImage: "gauge.with.needle") }
            DiagnosticsView(model: model, bench: bench)
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
                .badge(model.dtcs.count)
            AlertsView(model: model, store: ruleStore)
                .tabItem { Label("Alerts", systemImage: "bolt.fill") }
                .badge(model.alerts.count)
            DrivesView(model: model)
                .tabItem { Label("Drives", systemImage: "car.fill") }
        }
        .background(Theme.background)
    }
}
