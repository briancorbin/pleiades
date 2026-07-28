import Celaeno
import Maia
import SwiftUI

/// The diagnostics screen: MIL state, stored codes with knowledge-base
/// detail, and the (guarded) clear-codes action.
public struct DiagnosticsView: View {
    @ObservedObject var model: TelemetryModel
    let bench: ElectraSource?

    @AppStorage("alcyone.imperial") private var imperial = false
    @State private var confirmingClear = false

    public init(model: TelemetryModel, bench: ElectraSource? = nil) {
        self.model = model
        self.bench = bench
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                milCard
                if model.dtcs.isEmpty {
                    healthyCard
                } else {
                    ForEach(model.dtcs, id: \.code) { dtc in
                        dtcCard(dtc)
                    }
                }
                actions
                historySection
            }
            .padding(22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .confirmationDialog("Clear stored codes?", isPresented: $confirmingClear) {
            Button("Clear codes", role: .destructive) {
                Task { await model.clearDTCs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turns off the check-engine light and resets readiness monitors; the ECU relearns fuel trims over the next drives.")
        }
    }

    private var milOn: Bool {
        model.mil?.milOn == true
    }

    private var milCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "engine.combustion.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(milOn ? Theme.redline : Theme.textDim)
                Text(milOn ? "CHECK ENGINE LIGHT ON" : "CHECK ENGINE LIGHT OFF")
                    .font(.system(size: 12, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(milOn ? Theme.redline : Theme.text)
                Spacer()
                Text("\(model.dtcs.count) stored")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textDim)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                StatTile(label: "Run time", unit: "min", value: model.value(.runTime).map { $0 / 60 }, format: "%.1f")
                StatTile(label: "Distance w/ MIL", unit: distanceUnit, value: distance(model.value(.distanceWithMIL)))
                StatTile(label: "Since codes cleared", unit: distanceUnit, value: distance(model.value(.distanceSinceCleared)))
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var healthyCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(Theme.copper)
            Text("No stored trouble codes")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func dtcCard(_ dtc: DTC) -> some View {
        let info = dtc.info
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(dtc.code)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.copper)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.copper.opacity(0.12), in: Capsule())
                Text(dtc.system.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textDim)
                Spacer()
            }
            Text(info.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            causesSection(info)
            freezeSection(dtc)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func causesSection(_ info: DTCInfo) -> some View {
        if !info.likelyCauses.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("LIKELY CAUSES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.textDim)
                ForEach(info.likelyCauses, id: \.self) { cause in
                    Text("•  \(cause)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textDim)
                }
            }
        } else if info.isGeneric {
            Text("No local knowledge-base entry — category decoded from the SAE code structure.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
        }
    }

    @ViewBuilder
    private func freezeSection(_ dtc: DTC) -> some View {
        if model.freezeDTC?.code == dtc.code, !model.freezeFrame.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("AT TIME OF FAULT")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.copper)
                HStack(spacing: 16) {
                    ForEach(model.freezeFramePIDs, id: \.code) { pid in
                        freezeStat(pid)
                    }
                    Spacer()
                }
            }
            .padding(10)
            .background(Theme.copper.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func freezeStat(_ pid: PID) -> some View {
        if let value = model.freezeFrame[pid.code] {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.0f %@", value, pid.unit))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.text)
                Text(pid.name.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.textDim)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !model.history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("HISTORY")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                    Text("survives code clearing")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textDim)
                }
                ForEach(model.history.prefix(20)) { event in
                    historyRow(event)
                }
            }
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func historyRow(_ event: DTCEvent) -> some View {
        let stored = event.kind == .stored
        return HStack(spacing: 10) {
            Image(systemName: stored ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(stored ? Theme.copper : Theme.textDim)
            Text(event.code)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
            Text(event.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
            Spacer()
            Text(stored ? "stored" : "cleared")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(stored ? Theme.copper : Theme.textDim)
            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(Theme.textDim)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Clear codes") {
                confirmingClear = true
            }
            .buttonStyle(.bordered)
            .tint(Theme.redline)
            .disabled(model.dtcs.isEmpty)

            if bench != nil {
                Button("Inject fault (bench)") {
                    Task { await bench?.injectFault() }
                }
                .buttonStyle(.bordered)
                .tint(Theme.copper)
            }
            Spacer()
        }
    }

    private var distanceUnit: String { imperial ? "mi" : "km" }

    private func distance(_ km: Double?) -> Double? {
        guard let km else { return nil }
        return imperial ? Units.miles(km) : km
    }
}
