import Maia
import Sterope
import SwiftUI

/// The Alcyone dashboard. Platform-agnostic: the same view runs in the macOS
/// bench window today and the iPad shell later. When `bench` is present
/// (Electra), engine/throttle controls appear along the bottom.
public struct DashboardView: View {
    @ObservedObject var model: TelemetryModel
    let bench: ElectraSource?
    let sourceSelection: Binding<String>?

    @AppStorage("alcyone.imperial") private var imperial = false
    @State private var throttle = 0.0
    @State private var engineOn = false

    public init(
        model: TelemetryModel,
        bench: ElectraSource? = nil,
        sourceSelection: Binding<String>? = nil
    ) {
        self.model = model
        self.bench = bench
        self.sourceSelection = sourceSelection
    }

    public var body: some View {
        VStack(spacing: 18) {
            header
            alertBanners
            dtcRow
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

    private var header: some View {
        HStack {
            Text("ALCYONE")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .tracking(4)
                .foregroundStyle(Theme.text)
            Text("✦")
                .font(.system(size: 11))
                .foregroundStyle(Theme.copper)
            if model.isRecording {
                HStack(spacing: 4) {
                    Circle().fill(Theme.redline).frame(width: 6, height: 6)
                    Text("REC")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(Theme.redline)
                }
            }
            Spacer()
            if let sourceSelection {
                Menu {
                    ForEach(TelemetrySourceKind.available, id: \.rawValue) { kind in
                        Button(kind.displayName) {
                            sourceSelection.wrappedValue = kind.rawValue
                        }
                    }
                } label: {
                    sourceBadge
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                sourceBadge
            }
        }
    }

    private var sourceBadge: some View {
        Text(model.sourceLabel.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(bench == nil ? Theme.text : Theme.copper)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(
                Capsule().strokeBorder(
                    (bench == nil ? Theme.text : Theme.copper).opacity(0.4)
                )
            )
    }

    @ViewBuilder
    private var alertBanners: some View {
        if !model.alerts.isEmpty {
            VStack(spacing: 8) {
                ForEach(model.alerts) { alert in
                    alertRow(alert)
                }
            }
        }
    }

    private func alertRow(_ alert: Sterope.Alert) -> some View {
        let isCritical = alert.severity == .critical
        let color: Color = isCritical ? Theme.redline : Theme.copper
        let icon = isCritical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        let valueText = String(format: "%.0f %@", alert.value, alert.unit)
        return HStack(spacing: 10) {
            Image(systemName: icon)
            Text(alert.message)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(valueText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.5)))
    }

    @ViewBuilder
    private var dtcRow: some View {
        if model.mil?.milOn == true || !model.dtcs.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "engine.combustion.fill")
                    .foregroundStyle(Theme.redline)
                Text("CHECK ENGINE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.redline)
                ForEach(model.dtcs, id: \.code) { dtc in
                    dtcChip(dtc)
                }
                Spacer()
                Button("Clear codes") {
                    Task { await model.clearDTCs() }
                }
                .buttonStyle(.bordered)
                .tint(Theme.redline)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.redline.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func dtcChip(_ dtc: DTC) -> some View {
        Text(dtc.code)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.surface, in: Capsule())
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

            Button("Inject fault") {
                Task { await bench?.injectFault() }
            }
            .buttonStyle(.bordered)
            .tint(Theme.copper)

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
