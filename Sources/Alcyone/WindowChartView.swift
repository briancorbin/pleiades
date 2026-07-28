import Celaeno
import Charts
import Maia
import SwiftUI

/// The black-box movie: one PID at a time from a fault's telemetry window,
/// with the fault moment marked at t=0. Single series — the picker names it,
/// so no legend; the accent hue carries the line, status red is reserved for
/// the fault marker.
struct WindowChartView: View {
    let window: [WindowSample]
    @State private var selectedPID = "0C"

    private static let pidNames: [String: (name: String, unit: String)] =
        Dictionary(uniqueKeysWithValues: PID.all.map {
            (String(format: "%02X", $0.code), ($0.name, $0.unit))
        })

    private var availablePIDs: [String] {
        let present = Set(window.map(\.pid))
        return PID.all
            .map { String(format: "%02X", $0.code) }
            .filter { present.contains($0) }
    }

    private var samples: [WindowSample] {
        window.filter { $0.pid == selectedPID }.sorted { $0.t < $1.t }
    }

    private func label(for pid: String) -> String {
        Self.pidNames[pid]?.name ?? pid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            chart
        }
        .padding(10)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            if !availablePIDs.contains(selectedPID), let first = availablePIDs.first {
                selectedPID = first
            }
        }
    }

    private var header: some View {
        HStack {
            Text("FAULT WINDOW")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.copper)
            Text("t=0 is the fault")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Picker("Signal", selection: $selectedPID) {
                ForEach(availablePIDs, id: \.self) { pid in
                    Text(label(for: pid)).tag(pid)
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.copper)
        }
    }

    private var chart: some View {
        let unit = Self.pidNames[selectedPID]?.unit ?? ""
        return Chart {
            RuleMark(x: .value("Fault", 0))
                .foregroundStyle(Theme.redline.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Seconds", sample.t),
                    y: .value(unit, sample.value)
                )
                .foregroundStyle(Theme.copper)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.track)
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.track)
                AxisValueLabel()
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .chartXAxisLabel(alignment: .trailing) {
            Text("seconds from fault")
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
        }
        .frame(height: 150)
    }
}
