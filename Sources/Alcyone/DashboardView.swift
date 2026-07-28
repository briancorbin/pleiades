import Maia
import SwiftUI

/// The Alcyone dashboard. Platform-agnostic: the same view runs in the macOS
/// bench window today and the iPad shell later. When `bench` is present
/// (Electra), engine/throttle controls appear along the bottom.
public struct DashboardView: View {
    @ObservedObject var model: TelemetryModel
    let bench: ElectraSource?

    @AppStorage("alcyone.imperial") private var imperial = false
    @State private var throttle = 0.0
    @State private var engineOn = false

    public init(model: TelemetryModel, bench: ElectraSource? = nil) {
        self.model = model
        self.bench = bench
    }

    public var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 24) {
                RadialGauge(
                    label: "RPM",
                    unit: "rpm",
                    value: model.value(.rpm) ?? 0,
                    range: 0...7000,
                    redlineFrom: 6000
                )
                RadialGauge(
                    label: "Speed",
                    unit: imperial ? "mph" : "km/h",
                    value: speedDisplay,
                    range: imperial ? 0...140 : 0...220
                )
            }
            .frame(maxHeight: 340)

            HStack(spacing: 14) {
                BarGauge(
                    label: "Coolant",
                    unit: tempUnit,
                    value: tempDisplay(model.value(.coolantTemp)),
                    range: tempRange(40...130),
                    warnAbove: tempDisplay(110) ?? 110
                )
                BarGauge(
                    label: "Oil temp",
                    unit: tempUnit,
                    value: tempDisplay(model.value(.oilTemp)),
                    range: tempRange(40...150),
                    warnAbove: tempDisplay(120) ?? 120
                )
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                StatTile(label: "Throttle", unit: "%", value: model.value(.throttle))
                StatTile(label: "Load", unit: "%", value: model.value(.engineLoad))
                StatTile(label: "Battery", unit: "V", value: model.value(.controlModuleVoltage), format: "%.1f")
                StatTile(label: "Fuel", unit: "%", value: model.value(.fuelLevel))
                StatTile(label: "Intake air", unit: tempUnit, value: tempDisplay(model.value(.intakeAirTemp)))
                StatTile(label: "Ambient", unit: tempUnit, value: tempDisplay(model.value(.ambientAirTemp)))
                StatTile(label: "Manifold", unit: "kPa", value: model.value(.manifoldPressure))
                StatTile(label: "Timing", unit: "°BTDC", value: model.value(.timingAdvance), format: "%.1f")
            }

            Spacer(minLength: 0)

            if bench != nil {
                benchBar
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }

    private var benchBar: some View {
        HStack(spacing: 16) {
            Button(engineOn ? "Stop engine" : "Start engine") {
                engineOn.toggle()
                let on = engineOn
                Task { await bench?.setEngine(on: on) }
            }
            .buttonStyle(.borderedProminent)
            .tint(engineOn ? Theme.redline : Theme.copper)

            Text("Throttle")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.textDim)
            Slider(value: $throttle, in: 0...100)
                .frame(maxWidth: 320)
                .disabled(!engineOn)
                .onChange(of: throttle) { value in
                    Task { await bench?.setThrottle(value) }
                }

            Spacer()

            Picker("", selection: $imperial) {
                Text("Metric").tag(false)
                Text("Imperial").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var tempUnit: String { imperial ? "°F" : "°C" }

    private var speedDisplay: Double {
        let kmh = model.value(.speed) ?? 0
        return imperial ? Units.mph(kmh) : kmh
    }

    private func tempDisplay(_ celsius: Double?) -> Double? {
        guard let celsius else { return nil }
        return imperial ? Units.fahrenheit(celsius) : celsius
    }

    private func tempRange(_ celsius: ClosedRange<Double>) -> ClosedRange<Double> {
        imperial
            ? Units.fahrenheit(celsius.lowerBound)...Units.fahrenheit(celsius.upperBound)
            : celsius
    }
}
