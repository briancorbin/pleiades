import Sterope
import SwiftUI

/// Alcyone's top level: Dashboard, Diagnostics, and Alerts tabs, with badges
/// for stored codes and live alerts.
public struct RootView: View {
    @ObservedObject var model: TelemetryModel
    let bench: ElectraSource?
    let ruleStore: RuleStore

    public init(model: TelemetryModel, bench: ElectraSource? = nil, ruleStore: RuleStore) {
        self.model = model
        self.bench = bench
        self.ruleStore = ruleStore
    }

    public var body: some View {
        TabView {
            DashboardView(model: model, bench: bench)
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
